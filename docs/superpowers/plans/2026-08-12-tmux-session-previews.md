# Tmux Session Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional, focus-safe sidebar previews for already-opened tmux presentations, with an efficient last-frame mode and an application-wide bounded live mode.

**Architecture:** `GhosthubSettings` owns the persisted Off/Efficient/Live preference. A per-scene coordinator in `GhosthubApp` owns preview state and retained-presentation lifecycle, while an injectable application-scoped budget caps inactive live surfaces at four. `GhosthubTerminal` copies immutable thumbnails from each surface's IOSurface-backed layer and provides a noninteractive parking host. `GhosthubUI` owns only per-scene row expansion and renders opaque preview views supplied by the app layer; it never owns surfaces, timers, or tmux identities.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Core Image/Core Graphics, IOSurface, Combine, Swift Testing, XCTest-based TerminalSmoke, Astro, shell demo tooling, kata.

## Global Constraints

- Work against kata issue `aszg` and update it as implementation milestones land.
- Follow test-driven development: add one failing behavior test, run it to see the expected failure, implement the minimum behavior, and rerun it before broadening the change.
- Use Swift Testing for settings, budget, policy, and scene-model logic. Keep XCTest only for real AppKit/libghostty view and window lifecycle coverage in `GhosthubTerminalSmokeTests`.
- Never create a tmux or SSH attachment for a preview. Preview eligibility comes only from `retainedTmuxPresentations`.
- Never use `GHOSTTY_ACTION_RENDER`, `SurfaceRenderTracker`, an offscreen window, SVG reconstruction, disk persistence, or a second parent for a `TerminalSurfaceView`.
- Keep the active surface in the detail view. Park only inactive surfaces, at their existing size, inside the visible workspace window.
- Treat `(hostID, name, socketName)` as presentation lookup identity, but authorize cached pixels only with an equal verified `TmuxSessionIdentity`.
- Before every commit, use the mandatory `kenn:commit` skill. Never amend.
- Do not push while either this plan or the design spec is present. Remove both `docs/superpowers` artifacts in the final task before the first branch push.
- Do not open a pull request unless the user explicitly asks.

---

## Task 1: Persist the preview mode and expose it in Terminal settings

**Files:**

- Create: `Sources/Settings/SessionPreviewMode.swift`
- Modify: `Sources/Settings/SettingsStore.swift`
- Modify: `Sources/Settings/SettingsViewDraft.swift`
- Modify: `Sources/UI/SettingsView.swift`
- Modify: `Tests/Settings/SettingsStoreTests.swift`
- Modify: `Tests/Settings/SettingsViewDraftTests.swift`
- Modify: `Tests/UI/SettingsViewTests.swift`

- [ ] **Step 1: Add failing preference tests**

Add Swift Testing cases proving that a fresh isolated `UserDefaults` suite loads `.off`, all three raw values round-trip, an unknown raw value falls back to `.off`, and `SettingsViewDraft.persist(to:)` writes the selected value without marking terminal config for reload.

```swift
@Test("session previews default to off and persist independently")
@MainActor
func sessionPreviewModePersistence() {
    let store = makeStore()
    #expect(store.sessionPreviewMode == .off)

    store.setSessionPreviewMode(.live)
    let reloaded = makeStore(using: storeUserDefaults)
    #expect(reloaded.sessionPreviewMode == .live)
}
```

- [ ] **Step 2: Run the focused settings tests and confirm the missing API failure**

Run: `swift test --filter 'SettingsStoreTests|SettingsViewDraftTests'`

Expected: compilation fails because `SessionPreviewMode`, `sessionPreviewMode`, and `setSessionPreviewMode` do not exist.

- [ ] **Step 3: Add the preference model and persistence**

Create a public enum with these stable raw values and user-facing titles:

```swift
public enum SessionPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case efficient
    case live

    public var id: Self { self }
    public var title: String {
        switch self {
        case .off: "Off"
        case .efficient: "Efficient"
        case .live: "Live"
        }
    }
}
```

In `SettingsStore`, add `DefaultsKey.sessionPreviewMode`, `defaultSessionPreviewMode = .off`, a published read-only property, loading in both `init` and `reload`, and `setSessionPreviewMode(_:)` that writes only UserDefaults. In `SettingsViewDraft`, copy, compare, and persist the value while leaving `shouldReloadTerminalConfig` unchanged.

- [ ] **Step 4: Add the Terminal settings picker**

Add a `Session previews` section to `terminalDetail` with a picker bound to `draft.sessionPreviewMode`. Explain that Efficient stores last frames, Live refreshes up to two times per second and parks at most four inactive sessions application-wide, and Off avoids preview GPU work.

- [ ] **Step 5: Verify settings behavior**

Run: `swift test --filter 'SettingsStoreTests|SettingsViewDraftTests|SettingsViewTests'`

Expected: all focused tests pass.

- [ ] **Step 6: Format and commit**

Run: `make format`

Commit: `Add session preview preference`

---

## Task 2: Build deterministic preview state and the application-wide live budget

**Files:**

- Create: `Sources/App/TmuxSessionPreviewState.swift`
- Create: `Sources/App/LivePreviewBudget.swift`
- Create: `Tests/App/LivePreviewBudgetTests.swift`
- Create: `Tests/App/TmuxSessionPreviewStateTests.swift`

- [ ] **Step 1: Write failing budget tests**

Define test request IDs from a scene UUID plus a presentation key. Cover first-request ordering, the four-slot cap, idempotent requests, release, waiter promotion, releasing an entire scene, and an active request not consuming a slot.

```swift
let budget = LivePreviewBudget(limit: 4)
for request in requests.prefix(5) { budget.request(request) }
#expect(budget.granted == Set(requests.prefix(4)))
#expect(budget.isWaiting(requests[4]))
budget.release(requests[1])
#expect(budget.isGranted(requests[4]))
```

- [ ] **Step 2: Run the focused test and confirm failure**

Run: `swift test --filter LivePreviewBudgetTests`

Expected: compilation fails because the budget types do not exist.

- [ ] **Step 3: Implement the budget as observable main-actor state**

Add:

```swift
struct TmuxPreviewKey: Hashable, Sendable {
    let hostID: UUID
    let name: String
    let socketName: String?
}

struct LivePreviewRequestID: Hashable, Sendable {
    let sceneID: UUID
    let presentation: TmuxPreviewKey
}

@MainActor
final class LivePreviewBudget: ObservableObject {
    static let shared = LivePreviewBudget(limit: 4)
    @Published private(set) var granted: Set<LivePreviewRequestID>
    func request(_ id: LivePreviewRequestID)
    func release(_ id: LivePreviewRequestID)
    func release(sceneID: UUID)
    func isGranted(_ id: LivePreviewRequestID) -> Bool
    func isWaiting(_ id: LivePreviewRequestID) -> Bool
}
```

Keep a duplicate-free FIFO request array. Every mutation recomputes the first `limit` grants so tests and multiple scenes see deterministic promotion.

- [ ] **Step 4: Write failing preview-state transition tests**

Cover empty state, successful capture, unchanged seed, failed capture preserving the last image metadata, quarantine on reconnect, equal-identity restoration, missing/changed identity clearing, Live limit status, and clearing pixels/timestamps/seeds when mode becomes Off.

Use a small token in tests instead of `NSImage`; the pure state reducer should be generic over an image token or accept metadata separately from the AppKit image store.

- [ ] **Step 5: Implement pure state transitions**

Define a small reducer/state machine with these concepts:

```swift
enum TmuxPreviewPlaceholder: Equatable {
    case awaitingFirstFrame
    case reconnecting
    case disconnected
    case liveLimitReached
}

struct TmuxPreviewFrame<Image> {
    let image: Image
    let capturedAt: Date
    let ioSurfaceSeed: UInt32
    let identity: TmuxSessionIdentity
}
```

The state owns at most one visible or quarantined frame. Equal verified identity can restore a quarantined frame; nil or unequal identity deletes it. Off deletes all frame state. A failed capture never replaces a valid frame.

- [ ] **Step 6: Verify, format, and commit**

Run: `swift test --filter 'LivePreviewBudgetTests|TmuxSessionPreviewStateTests'`

Run: `make format`

Commit: `Add bounded preview state model`

---

## Task 3: Copy immutable thumbnails from the IOSurface-backed layer

**Files:**

- Create: `Sources/Terminal/TerminalSurfaceSnapshotter.swift`
- Create: `Tests/TerminalSmoke/TerminalSurfacePreviewTests.swift`
- Modify: `Package.swift` only if explicit framework linkage is required by the compiler

- [ ] **Step 1: Add a real-surface smoke test for capture**

Using `TerminalSmokeFixtures`, create a real `TerminalSurfaceView`, place it in a visible test window, wait for a rendered frame, and request a 320x200 thumbnail. Assert a nonempty immutable image, exact 16:10 output dimensions, and no change to surface frame, grid size, input routing, or superview.

- [ ] **Step 2: Add unchanged-seed and failure tests**

Request a second snapshot with the first result's seed and assert the snapshotter returns an unchanged result without a new bitmap. Also cover missing layer contents and zero output size; both must report preview-local failure without changing the surface.

- [ ] **Step 3: Run the new smoke suite and confirm failure**

Run: `swift test --filter TerminalSurfacePreviewTests`

Expected: compilation fails because `TerminalSurfaceSnapshotter` is missing.

- [ ] **Step 4: Implement the main-actor snapshot API**

Expose:

```swift
public struct TerminalSurfaceSnapshot {
    public let image: NSImage
    public let ioSurfaceSeed: UInt32
}

@MainActor
public final class TerminalSurfaceSnapshotter {
    public func snapshot(
        of surface: TerminalSurfaceView,
        outputSize: CGSize,
        previousSeed: UInt32?
    ) async throws -> TerminalSurfaceSnapshot?
}
```

Read only `surface.layer?.contents`. Require IOSurface-backed content, compare `IOSurfaceGetSeed` before copying, and return `nil` when the seed is unchanged. Convert the IOSurface through Core Image/Core Graphics into owned pixels, then draw it scaled-to-fit into an opaque 16:10 bitmap using the terminal background color for letterboxing. Never retain the IOSurface in the result.

- [ ] **Step 5: Serialize/coalesce per-surface work**

Key in-flight requests by `ObjectIdentifier(surface)`. Coalesce concurrent requests for the same surface and clear the entry with `defer`. Keep all surface/layer reads on `@MainActor`; bitmap rendering may move to a detached value-only operation only after the source has been safely copied.

- [ ] **Step 6: Verify, format, and commit**

Run: `swift test --filter TerminalSurfacePreviewTests`

Run: `make format`

Commit: `Capture immutable terminal preview frames`

---

## Task 4: Make parked surfaces structurally noninteractive and size-stable

**Files:**

- Modify: `Sources/Terminal/TerminalSurfaceView.swift`
- Create: `Sources/Terminal/LivePreviewParkingHost.swift`
- Modify: `Sources/App/BorrowedTmuxSessionView.swift`
- Modify: `Tests/TerminalSmoke/TerminalSurfacePreviewTests.swift`

- [ ] **Step 1: Add failing focus, hit-testing, accessibility, and size tests**

Extend the smoke suite to prove:

- setting parked state while the surface is first responder resigns it;
- `acceptsFirstResponder` and `canBecomeKeyView` are false while parked, without
  mutating next/previous key-view links;
- parking sets `suppressAutoFocus` before `viewDidMoveToWindow` can run;
- the container's `hitTest(_:)` returns nil and it exposes no accessibility children;
- parking into a visible covered host preserves `frame.size`, `surfaceSize`, and grid dimensions;
- unpark marks the surface occluded until the normal detail mount;
- a parked surface remains attached to the visible test window and renderable.

- [ ] **Step 2: Run the smoke test and confirm failure**

Run: `swift test --filter TerminalSurfacePreviewTests`

Expected: the parked-state and parking-host APIs are missing.

- [ ] **Step 3: Add explicit parked state to `TerminalSurfaceView`**

Add `public private(set) var isParkedForPreview` and one transition method:

```swift
public func setParkedForPreview(_ parked: Bool)
```

When entering parked state, set `suppressAutoFocus = true`, resign any AppKit
and libghostty focus, and make `acceptsFirstResponder` and `canBecomeKeyView`
return false. Do not mutate next/previous key-view links. Guard imperative focus
and primary mouse paths against parked state as a second line of defense.
Leaving parked state restores eligibility through those reversible overrides but
does not request focus; the normal tmux mount owns that request.

- [ ] **Step 4: Implement `LivePreviewParkingHost`**

The host is a layer-backed, non-flipped `NSView` whose `hitTest(_:)` always returns nil and whose accessibility children are empty. Its API should make ownership explicit:

```swift
@MainActor
public final class LivePreviewParkingHost: NSView {
    public func park(_ surface: TerminalSurfaceView) throws
    public func unpark(_ surface: TerminalSurfaceView)
    public func unparkAll()
    public func contains(_ surface: TerminalSurfaceView) -> Bool
}
```

`park` records the existing frame/bounds size, enters parked state before `addSubview`, reuses that exact size, and fails if the surface is still mounted somewhere other than the normal detail host. It never scales a surface to thumbnail dimensions.

- [ ] **Step 5: Make normal tmux mounting clear parked state**

In `NativeTmuxTerminalView.onAppear`, call `setParkedForPreview(false)` before resetting `suppressAutoFocus` and asynchronously requesting keyboard focus. Its `onDisappear` must not itself park; the scene coordinator owns that decision.

- [ ] **Step 6: Verify, format, and commit**

Run: `swift test --filter TerminalSurfacePreviewTests`

Run: `make format`

Commit: `Add focus-safe terminal preview parking`

---

## Task 5: Implement the per-scene preview coordinator

**Files:**

- Create: `Sources/App/TmuxSessionPreviewCoordinator.swift`
- Create: `Sources/App/TmuxSessionPreviewViews.swift`
- Modify: `Sources/App/WorkspaceSceneModel.swift`
- Modify: `Sources/App/WorkspaceSceneModel+Subscriptions.swift`
- Modify: `Tests/App/SceneModelTestSupport.swift`
- Create: `Tests/App/TmuxSessionPreviewCoordinatorTests.swift`

- [x] **Step 1: Add failing coordinator tests with injected collaborators**

Inject a budget, clock, snapshot closure, 500ms Live clock, 250ms activation delay, key-window predicate, and park/unpark closures. Cover:

- Off, Efficient, and Live mode transitions;
- expanding active Efficient captures once;
- expanded inactive Efficient never polls or parks;
- Live ticks capture only expanded active and granted parked surfaces at no more than 2fps;
- active routing never invokes park;
- inactive routing uses the budget and publishes the limit placeholder for waiters;
- Live -> Efficient takes a final parked capture, then unparks while retaining frames;
- any -> Off unparks and clears images, timestamps, seeds, timers, and requests;
- capture failure preserves the prior frame;
- sidebar hiding releases only the coordinator's scene requests;
- app deactivation releases all requests immediately;
- app activation waits 250ms and revalidates the activation generation,
  current app-active state, and key-window predicate before reacquiring;
- activate followed by resign before the delay completes never reacquires a
  slot or parks a surface;
- suspended snapshot completions cannot publish after Off, removal,
  replacement, or reconnect invalidates their capture generation.

- [x] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter TmuxSessionPreviewCoordinatorTests`

Expected: compilation fails because the coordinator is missing.

- [x] **Step 3: Implement coordinator inputs and published view state**

Use an internal main-actor observable object:

```swift
@MainActor
final class TmuxSessionPreviewCoordinator: ObservableObject {
    let sceneID: UUID
    @Published private(set) var viewStates: [TmuxPreviewKey: TmuxPreviewViewState]

    func register(_ presentation: Presentation)
    func setExpanded(_ expanded: Bool, for key: TmuxPreviewKey)
    func setMode(_ mode: SessionPreviewMode)
    func setSidebarVisible(_ visible: Bool)
    func applicationDidResignActive()
    func applicationDidBecomeActive()
    func prepareToActivate(_ key: TmuxPreviewKey)
    func remove(_ key: TmuxPreviewKey, reason: RemovalReason)
}
```

`Presentation` supplies the current surface, connection state, generation, and verified identity through closures so the coordinator does not create attachments. The coordinator subscribes to `LivePreviewBudget.$granted`, owns one coalescing Live task per scene, and publishes immutable `NSImage` view state.

Every capture receives a coordinator generation token. After any suspension,
the completion revalidates that token together with mode, presentation
generation, current handle, verified identity, application activity, sidebar
visibility, row expansion, connection state, and (for a parked surface) the
current budget grant before publishing. Off, removal, replacement, reconnect,
deactivation, sidebar hiding, row collapse, and grant revocation advance the
generation and cancel pending capture work. Activation-delay tasks use the same
pattern: every eligibility transition cancels the task and advances an
activation generation, and delayed reacquisition revalidates the generation,
Live mode, application activity, scene sidebar visibility, row expansion,
connection state, budget grant, and key-window ownership before parking.

- [x] **Step 4: Implement parking and click handoff order**

On inactive Live eligibility: request a slot, then park only after a host is installed and the surface has left the detail parent. On tile activation: stop scheduling that key, final-capture best effort, unpark, release the slot, then invoke the existing open-selection action. Record the steps through injected closures so the test asserts capture -> unpark -> activate.

- [x] **Step 5: Add the opaque SwiftUI/AppKit adapters**

In `TmuxSessionPreviewViews.swift`, add:

- `TmuxSessionPreviewTile`, observing the coordinator and rendering the 16:10 `scaledToFit` image/placeholder/status;
- `TmuxSessionPreviewParkingView`, an `NSViewRepresentable` that installs the coordinator's `LivePreviewParkingHost` inside the detail area and unregisters it on dismantle.

The tile supplies one combined VoiceOver label describing session, live/retained status, relative update time, connection state, and limit state. It contains no surface or timer.

- [x] **Step 6: Wire app activity into the coordinator**

Create the coordinator in `WorkspaceSceneModel.init`, defaulting to `LivePreviewBudget.shared` and `TerminalSurfaceSnapshotter`, with injectable substitutes in `SceneModelTestSupport.makeModel`. Forward the existing app-active notifications from `WorkspaceSceneModel+Subscriptions` in addition to resource-monitoring behavior.

- [x] **Step 7: Verify, format, and commit**

Run: `swift test --filter 'TmuxSessionPreviewCoordinatorTests|LivePreviewBudgetTests'`

Run: `make format`

Commit: `Coordinate bounded tmux previews per scene`

---

## Task 6: Bind retained tmux lifecycle and identity fencing

**Files:**

- Modify: `Sources/App/WorkspaceSceneModel.swift`
- Modify: `Sources/App/NativeTmuxSessionCoordinator.swift` only if a read-only current-identity accessor is needed
- Modify: `Tests/App/WorkspaceTmuxDiscoveryTests.swift`
- Modify: `Tests/App/TmuxSessionPreviewCoordinatorTests.swift`

- [x] **Step 1: Add failing retained-presentation lifecycle tests**

Using the existing scene-model harness, cover:

- opening a presentation registers exactly one eligible preview without increasing attachment count;
- outgoing capture before tmux-to-tmux activation;
- outgoing capture before tmux-to-Herdr, tmux-to-Zellij, no-presentation navigation, and explicit close;
- close and invalidation remove both cached frame and parking request;
- a non-nil worktree generation replacement clears old pixels even when endpoint key is reused;
- transport reconnect releases the stale surface and budget slot while quarantining the frame;
- equal verified `TmuxSessionIdentity` restores the frame;
- nil or changed server PID/session ID/creation time clears it;
- an initially connected protected-socket or newly created session with no
  discovery identity reads and stores its identity before its first capture;
- a suspended initial identity read is discarded after handle, endpoint, or
  generation replacement.

- [x] **Step 2: Run focused tests and confirm failures**

Run: `swift test --filter 'WorkspaceTmuxDiscoveryTests|TmuxSessionPreviewCoordinatorTests'`

Expected: the new lifecycle assertions fail because retained presentations do not notify the preview coordinator.

- [x] **Step 3: Make presentation identity explicit**

Move `TmuxPresentationKey` to file scope if necessary for coordinator use,
preserving exactly `hostID`, `name`, and `socketName`. Store the current verified
`TmuxSessionIdentity?` on `RetainedTmuxPresentation`; seed it from
`discoveredTmuxSessionIdentity` on initial attachment when available. When an
ordinary attachment first reports connected without a verified identity,
including protected-socket and newly created sessions, use the existing
injected `tmuxSessionIdentityReader` to read it before enabling capture.
Revalidate presentation endpoint, handle, connection state, and generation
after the asynchronous read before storing the identity.

For reconnect, clear the parked surface immediately and quarantine the frame. After connection recovery reports connected, use the existing injected `tmuxSessionIdentityReader` to verify the exact identity. Reuse the frame only on equality; clear it on missing/changed identity. Pass the verified identity into any relaunched attachment that supports the existing identity fence.

- [x] **Step 4: Centralize every active-presentation transition**

Before any active tmux presentation is replaced or cleared, call one helper that captures the outgoing surface according to mode and expansion, then handles Live parking eligibility. Route `activateTmuxPresentation`, `hideBorrowedTmuxSession`, Herdr/Zellij activation, selection of content without a presentation, and explicit close through it. Do not rely only on SwiftUI `onDisappear`.

- [x] **Step 5: Register, update, and remove retained presentations**

Register only after the ordinary retained presentation exists. Update handle/surface/connection closures when reconnect replaces a handle. Remove on close, invalidation, authoritative inventory removal, shutdown, and generation replacement. Expose a read-only `previewableTmuxSessionIDs: Set<String>` derived from retained keys for sidebar eligibility; never derive eligibility from inventory alone.

- [x] **Step 6: Verify attachment-count and identity safety**

Run: `swift test --filter 'WorkspaceTmuxDiscoveryTests|TmuxSessionPreviewCoordinatorTests|NativeTmuxSessionCoordinatorTests'`

Expected: all focused tests pass and the existing attachment-count assertions remain unchanged.

- [x] **Step 7: Format and commit**

Run: `make format`

Commit: `Fence previews to retained tmux identities`

---

## Task 7: Render expandable preview tiles in the sidebar and install the parking host

**Files:**

- Modify: `Sources/UI/RootViewConfiguration.swift`
- Modify: `Sources/UI/RootView.swift`
- Modify: `Sources/UI/WorkspaceSidebarView.swift`
- Modify: `Sources/App/WorkspaceWindow.swift`
- Modify: `Tests/UI/WorkspaceSidebarViewTests.swift`
- Modify: `Tests/UI/SidebarToggleStabilityTests.swift`
- Modify: `Tests/TerminalSmoke/TerminalSurfacePreviewTests.swift`

- [x] **Step 1: Add failing pure UI tests**

Add a small row-presentation model test proving disclosure is shown only when mode is not Off and the exact retained presentation ID is eligible. Cover memory-only expansion, Off preserving the expansion set while hiding controls, 16:10 sizing, and preview click using the same tmux selection callback as the row.

- [x] **Step 2: Run UI tests and confirm failure**

Run: `swift test --filter 'WorkspaceSidebarViewTests|SidebarToggleStabilityTests'`

Expected: missing preview presentation model/builders.

- [x] **Step 3: Extend the UI boundary with opaque builders**

Add to `WorkspaceDisplayState` the set of eligible retained presentation IDs. Add to `ContentBuilders`:

```swift
public let tmuxSessionPreviewBuilder:
    ((WorkspaceTmuxSessionSelection) -> AnyView?)?
public let tmuxSessionPreviewParkingBuilder: (() -> AnyView?)?
```

Add to `InteractionHandlers` a `setTmuxSessionPreviewExpanded` callback and a preview-selection callback that lets the scene coordinator complete unpark handoff before ordinary activation. Keep `GhosthubUI` independent of `GhosthubTerminal` and `GhosthubTmux`.

- [x] **Step 4: Add per-scene expansion and tile layout**

In `WorkspaceSidebarView`, store `@State private var expandedTmuxPreviewIDs: Set<String> = []`. Wrap eligible tmux rows in a vertical container with a disclosure button. When expanded, render the opaque preview view at `.aspectRatio(16 / 10, contentMode: .fit)`. The tile button calls the preview-selection callback. Use the exact selection `id` (`hostID:socketName:name`) instead of sidebar row UUID.

- [x] **Step 5: Install the covered parking host in the visible detail column**

Change `terminalWorkspaceContent` to a `ZStack`: optional parking host at the back, an opaque `WorkspaceSurfaceColor` cover, then the normal detail content. The parking host remains in the same visible `NSWindow`, but cannot be seen or hit. Forward `isSidebarVisible` changes to the scene coordinator; hiding one sidebar releases only that scene.

- [x] **Step 6: Wire builders in `WorkspaceWindow`**

Pass `settingsStore.sessionPreviewMode`, `sceneModel.previewableTmuxSessionIDs`, preview tile builder, parking builder, expansion changes, and ordered preview activation into `RootView`. Observe settings mode changes in the scene model/coordinator so mode transitions take effect immediately.

- [x] **Step 7: Add the real click-handoff smoke test**

Mount an inactive surface in the parking host, invoke the preview selection path, and assert final capture -> unpark/occlude -> ordinary `BorrowedTmuxSessionView` mount -> parked-state clear -> focus request. Assert at every checkpoint that the surface has at most one superview.

- [x] **Step 8: Verify, format, and commit**

Run: `swift test --filter 'WorkspaceSidebarViewTests|SidebarToggleStabilityTests|TerminalSurfacePreviewTests'`

Run: `make format`

Commit: `Show expandable tmux previews in the sidebar`

---

## Task 8: Update architectural and user-facing documentation

**Files:**

- Modify: `AGENTS.md` (`CLAUDE.md` is its symlink; do not edit it separately)
- Modify: `docs/architecture.md`
- Modify: `docs/terminal-sessions.md`
- Modify: `website/docs/content/sessions.md`
- Modify: `website/docs/content/terminal-configuration.md`
- Modify: `website/src/pages/overview.astro`
- Modify: `website/demo/shoot.sh`
- Modify: `Tests/test_demo_scripts.py`

- [x] **Step 1: Update the ownership invariant everywhere it appears**

Replace “one client” wording with: each scene has at most one active interactive native presentation; already-opened retained tmux clients may remain noninteractive and render only for explicitly enabled previews. State that tmux still owns panes/layout/history and previews never create another client.

- [x] **Step 2: Document user behavior and cost**

In website session and terminal-configuration docs, describe Settings -> Terminal -> Session previews, Off/Efficient/Live behavior, already-opened-only scope, per-scene disclosure memory, the two-frames-per-second ceiling, the four-inactive-preview application cap, reconnect placeholders, and bitmap letterboxing.

- [x] **Step 3: Add the visual Guide section and asset contract**

Import `guide-session-previews.png` in `website/src/pages/overview.astro`, add a session-previews section with a `ZoomableImage`, and add the filename to `Tests/test_demo_scripts.py`. Extend `website/demo/shoot.sh` to enable Live through the deterministic demo controller, open two synthetic tmux sessions, return to the first, expand the inactive retained row, wait for a frame, and capture `guide-session-previews.png` without real data.

- [x] **Step 4: Run documentation and demo-script tests**

Run: `make python-test`

Run: `make docs-build`

Expected: both pass; the docs build may use its allowed placeholder path until the acceptance screenshot is published.

- [x] **Step 5: Commit docs and deterministic capture support**

Commit: `Document tmux session previews`

---

## Task 9: Run required gates and inspect the complete implementation

**Files:** Review all files changed since `f6af18f` except the local Superpowers artifacts.

- [ ] **Step 1: Run formatting and bootstrap checks**

Run:

```sh
make format
make format-check
make test-libghostty-bootstrap
```

Expected: all pass. A libghostty bootstrap schema bump is not expected because this design does not patch libghostty.

- [ ] **Step 2: Run Python and Swift suites**

Run:

```sh
make python-test
swift test
```

Expected: all tests pass, including settings, UI, scene lifecycle, TerminalSmoke, and demo tooling.

- [ ] **Step 3: Run native attachment and build gates**

Run:

```sh
make test-essential-workflows
make build
make docs-build
```

Expected: all pass.

- [ ] **Step 4: Review the diff for forbidden scope**

Run:

```sh
git diff --check f6af18f...HEAD
git diff --stat f6af18f...HEAD
git status --short
```

Inspect the full diff and confirm: no pane projection; no additional tmux/SSH attach call; no disk write of terminal pixels; no active-surface reparent; no surface resize while parking; no render callback dependency; no focus/input/accessibility path into parked surfaces; no cached image displayed without equal identity after reconnect.

- [ ] **Step 5: Commit any verification fixes separately**

For each discovered defect, first add/strengthen the narrowest regression test, then fix it, rerun the focused test and affected gate, run `make format`, and create a non-amended commit describing the fix.

---

## Task 10: Capture acceptance assets, remove local artifacts, and push

**Files:**

- Generate outside the task branch: `/tmp/ghosthub-website-assets/guide-session-previews.png`
- Remove before push: `docs/superpowers/specs/2026-08-12-session-previews-design.md`
- Remove before push: `docs/superpowers/plans/2026-08-12-tmux-session-previews.md`

- [ ] **Step 1: Capture the complete deterministic screenshot set**

Run exactly the guarded demo workflow from `website/README.md`:

```sh
cd website/demo
./stage.sh
./run.sh
./shoot.sh /tmp/ghosthub-website-assets
GHOSTHUB_DEMO_EXE_ACCOUNTS=1 ./run.sh
GHOSTHUB_DEMO_EXE_ONLY=1 ./shoot.sh /tmp/ghosthub-website-assets
./teardown.sh
```

Always run `./teardown.sh`, including after a failure. Inspect `guide-session-previews.png` for the expanded preview, synthetic-only data, readable status, correct letterboxing, and current UI.

- [ ] **Step 2: Publish screenshot binaries on `website-assets`**

Use a temporary worktree for the orphan `website-assets` branch so the feature worktree remains untouched. Copy the generated screenshot set into that branch's expected root, commit it there, and push `website-assets`. Do not merge screenshot binaries into `session-previews`.

- [ ] **Step 3: Rebuild docs against the published asset**

Back in the feature worktree, remove any locally materialized ignored assets, then run `make docs-build` without placeholder overrides. Confirm `website/scripts/sync-assets.sh` fetches the new committed asset and the Guide builds successfully.

- [ ] **Step 4: Close the kata issue only after acceptance is complete**

Run:

```sh
kata comment aszg --body "Implemented optional retained tmux session previews with Off/Efficient/Live modes, identity-fenced frames, focus-safe live parking, bounded app-wide allocation, documentation, and deterministic acceptance imagery. All required gates passed."
kata close aszg --reason done --json
```

- [ ] **Step 5: Remove local Superpowers artifacts and commit the removal**

Delete the design spec and this plan with `apply_patch`. Verify no files remain under `docs/superpowers/specs/` or `docs/superpowers/plans/`, then commit:

`Remove local session preview planning artifacts`

- [ ] **Step 6: Re-run final cleanliness checks and push the task branch**

Run:

```sh
git status --short
git diff --check origin/main...HEAD
make build
git push -u origin session-previews
```

Expected: the worktree is clean before push, the build passes freshly, and the branch contains no Superpowers artifacts. Do not open a pull request unless explicitly requested.
