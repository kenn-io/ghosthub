# Rex Split Tree Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This user wants inline execution.

**Goal:** Show a whole Rex window in Ghosthub as a fast AppKit split view of libghostty panes, drawn from Rex's layout and driven through one kwt control channel.

**Architecture:** kwt gains `kwt rex control WINDOW_ID`, a JSON-lines proxy that streams Rex's session view and forwards an allowlist of layout requests. Ghosthub maps each view to a backend-neutral `TerminalSplitTree`, lays it out with a pure function, and applies frames to one AppKit container whose panes are the existing per-block `kwt rex attach` surfaces.

**Tech Stack:** Go (kwt, coder/websocket, cobra); Swift 6 / AppKit / SwiftUI host, libghostty surfaces, Swift Testing + XCTest.

**Spec:** `docs/superpowers/specs/2026-11-17-rex-split-tree-design.md`

## Global Constraints

- Public repositories (kwt, ghosthub): scan every commit, PR, and comment with `~/.config/kenn/private-terms.txt`; no private names, hosts, or kata IDs.
- New commits only; never amend; never `--no-verify`. Merge only with the user's authorization.
- Ghosthub never invents a layout: every pane position comes from Rex's view.
- ⌘W keeps Ghosthub's meaning (close the view; panes keep running). Close Pane needs confirmation.
- A drag must not resize any terminal before mouse-up, and sends one `session.resize_pane` after it.
- A pane that survives a layout change keeps its card and terminal view.
- Do not disturb the user's Rex sessions; real-app checks use a throwaway session that is deleted afterwards.
- No compatibility scaffolding: the per-pane Rex rows are replaced, not kept beside window rows.
- Ghosthub tests: `make swift-test SWIFT_TEST_FILTER=...`; full `make swift-test` before each push. kwt: `go test ./internal/rex/... ./internal/cmd/...` and the repo's lint gate.

---

## Part A: kwt (worktree `~/code/worktrees/kwt-rex-control`, branch `feat/rex-control` from `origin/main`)

### Task A1: Deliver Rex events from the client

**Files:**
- Modify: `internal/rex/client.go` (read loop, new `Events`)
- Modify: `internal/rex/fake_server_test.go` (push events)
- Test: `internal/rex/client_test.go`

**Interfaces:**
- Produces: `type Event struct { SessionID string; Type string; Payload json.RawMessage }` and `func (c *Client) Events() <-chan Event`. The channel is buffered (256); when full, the oldest event is dropped and `Event{Type: "overflow"}` is delivered next so a consumer re-reads the view. The channel closes when the connection ends.
- Wire format (observed from Rex 0.1.0-preview.14): `{"type":"session_event","payload":{"session_id":S,"event":{"type":T,"payload":P}}}`. Block events have `T == "block_event"` and `P == {"block_id","creator_name","name","payload"}`.

- [ ] Step 1: Fake server gains `push(sessionID string, event map[string]any)` that writes a `session_event` frame to every open control connection.
- [ ] Step 2: Failing test `TestClientDeliversSessionEvents`: dial the fake, `push(S, {"type":"session_view_changed","payload":{"revision":3}})`, expect `Event{SessionID:S, Type:"session_view_changed"}` within 1s.
- [ ] Step 3: Failing test `TestClientEventsCloseWithConnection`: close the fake connection; `Events()` closes.
- [ ] Step 4: Implement: in `read`, decode `type == "session_event"` into `Event` and send non-blocking with the overflow rule; close the channel in the read loop's defer.
- [ ] Step 5: `go test ./internal/rex/...` passes; commit `feat(rex): deliver session events from the control client`.

### Task A2: Control loop

**Files:**
- Create: `internal/rex/control.go`
- Test: `internal/rex/control_test.go`

**Interfaces:**
- Consumes: `Client.Events`, `Client.Call`, `Client.BlockCall`, existing `sessionView` decoding helpers, `displayName`.
- Produces: `func Control(ctx context.Context, client *Client, windowID string, in io.Reader, out io.Writer) error`.
  - Finds the session holding `windowID` (`session.list`, then `session.attach` each until the window appears; detaches the rest). Missing window: returns `ErrWindowNotFound`.
  - Writes `{"type":"view","view":RAW_SESSION_VIEW,"terminals":{BLOCK:{"name","title","program","cwd"}}}` after attach and after `session_view_changed`, `overflow`, or a terminal `block_event` named `title_changed`, `pwd_changed`, `process_changed`. One read in flight; a change during a read schedules exactly one more.
  - Reads request lines `{"id":N,"method":M,"params":{...}}`; M must be one of `session.new_split session.resize_pane session.focus_block session.focus_direction session.focus_next_pane session.focus_previous_pane session.zoom_block block.close`; sets `params.session_id`; writes `{"type":"reply","id":N,"result":R}` or `{"type":"reply","id":N,"error":{"code","message"}}` (`code:"method_not_allowed"` for the rest). Requests run concurrently with view reads; output lines are written under one mutex.
  - `session_destroyed` for the session: writes `{"type":"ended"}` and returns nil. EOF on `in` returns nil. A lost connection returns `ErrDisconnected`.

- [ ] Step 1: Failing tests against the fake server:
  - `TestControlWritesInitialView` — fake answers `session.list`, `session.attach` (view with window W), terminal `title`/`process`; first output line is a `view` with `terminals[B].name`.
  - `TestControlCoalescesViewChanges` — push 5 `session_view_changed` while the fake delays `session.view`; at most 2 further `view` lines.
  - `TestControlForwardsAllowedRequest` — write `{"id":7,"method":"session.new_split","params":{"anchor_id":B,"direction":"horizontal","side":"after","focus":true,"layout":{"block":{"flavor":"com.superlogical.terminal.shell"}}}}`; fake records `session_id` set; reply line has `"id":7` and the result.
  - `TestControlRejectsOtherMethods` — `session.destroy` gets `method_not_allowed`, fake records no call.
  - `TestControlEndsWithSession` — push `session_destroyed`; output ends with `{"type":"ended"}`; returns nil.
  - `TestControlMissingWindow` — `ErrWindowNotFound`.
- [ ] Step 2: Run, see failures.
- [ ] Step 3: Implement `control.go` (event loop goroutine + request reader goroutine + `sync.Mutex` writer; refresh state `reading bool; again bool`).
- [ ] Step 4: Tests pass; commit `feat(rex): stream a window's layout and forward layout requests`.

### Task A3: `kwt rex control` command and docs

**Files:**
- Modify: `internal/cmd/rex.go` (new subcommand), `internal/cmd/rex_test.go`
- Modify: the kwt docs page that documents `kwt rex` (find with `rg -l "rex attach" docs README.md`).

**Interfaces:**
- Produces: `kwt rex control WINDOW_ID` — validates `^window:[0-9A-Za-z-]+$`, finds the server (never starts one), dials, runs `rex.Control` with stdin/stdout, exit 0 on ended/EOF, non-zero with stderr message otherwise.

- [ ] Step 1: Failing cmd test: invalid window ID exits non-zero without dialing; with the fake server reachable through the test's `REX_SERVER`-style hook used by existing rex cmd tests, the first stdout line is a `view`.
- [ ] Step 2: Implement; update help text and docs (contract of the JSON lines).
- [ ] Step 3: `go test ./...` for touched packages + repo lint; private-terms scan; commit `feat(rex): add kwt rex control`.
- [ ] Step 4: Manual check against the local Rex server with a throwaway session: `kwt rex control WINDOW` prints a view; a `new_split` request splits; kill the session → `ended`. Delete the session.
- [ ] Step 5: Push, open PR (pr-desc), report. Ghosthub pins kwt only after this merges.

## Part B: Ghosthub (branch `feat/rex-split-view` from `origin/main`)

### Task B1: Split tree and layout (pure)

**Files:**
- Create: `Sources/TerminalSupport/TerminalSplitTree.swift`
- Create: `Sources/TerminalSupport/TerminalSplitLayout.swift`
- Test: `Tests/TerminalSupport/TerminalSplitLayoutTests.swift` (follow the existing test target layout; check `Package.swift` for the TerminalSupport test target name)

**Interfaces:**
```swift
public struct TerminalSplitTree: Equatable, Sendable {
    public indirect enum Node: Equatable, Sendable {
        case pane(String)
        case split(id: String, axis: Axis, ratio: Double, first: Node, second: Node)
    }
    public enum Axis: Equatable, Sendable { case horizontal, vertical } // horizontal = side by side
    public var root: Node
    public var focusedPaneID: String?
    public var zoomedPaneID: String?
    public var paneIDs: [String]   // layout order
}

public struct TerminalSplitMetrics: Equatable, Sendable {
    public var gap: CGFloat = 8
    public var minimumPaneSize = CGSize(width: 80, height: 60)
}

public struct TerminalSplitDivider: Equatable, Sendable {
    public var splitID: String
    public var axis: TerminalSplitTree.Axis
    public var hitRect: CGRect        // the gap, widened to 6pt min
    public var parentRect: CGRect     // the split's whole rect
    public var ratioRange: ClosedRange<Double> // clamped by minimum pane size
    public var firstPaneID: String    // nearest pane on each side, for accessibility and resize_pane
    public var secondPaneID: String
}

public enum TerminalSplitLayout {
    public static func frames(
        for tree: TerminalSplitTree, in bounds: CGRect,
        metrics: TerminalSplitMetrics, scale: CGFloat,
        ratioOverrides: [String: Double] = [:]
    ) -> (panes: [String: CGRect], dividers: [TerminalSplitDivider])
    public static func ratio(for point: CGPoint, divider: TerminalSplitDivider,
                             metrics: TerminalSplitMetrics) -> Double
}
```
Rules: a split of `rect` along its axis gives `first` `floor(available * ratio)` (pixel-snapped at `scale`) and `second` the rest, with `gap` between; `available = length - gap`. Zoomed: only the zoomed pane gets `bounds`, no dividers. `firstPaneID` = last pane of `first` subtree in layout order nearest the divider (rightmost/bottom-most leaf), `secondPaneID` = first leaf of `second`.

- [ ] Step 1: Failing tests:
  - single pane fills bounds;
  - the captured Rex probe tree (horizontal 0.5 → [A, vertical 0.6 → [B, C]]) in `CGRect(0,0,1000,600)` gap 8 scale 2: A = `(0,0,496,600)`, B = `(504,0,496,355.0)` C = `(504,363,496,237)` (compute exactly in the test from the rule, assert pixel alignment `x*2` integral);
  - divider hit rects sit in the gaps; `firstPaneID/secondPaneID` are A/B for the root;
  - `ratioOverrides[rootSplit] = 0.3` moves frames;
  - `ratioRange` keeps both sides ≥ minimum;
  - zoomed tree returns one frame and no dividers;
  - 16-pane balanced tree: 1000 iterations finish < 1 s (≈ <1 ms each).
- [ ] Step 2: Implement; tests pass; commit `feat(terminal): lay out split trees`.

### Task B2: Rex view → split tree

**Files:**
- Create: `Sources/BackendTerminal/RexWindowView.swift`
- Test fixture: `Tests/BackendTerminal/Fixtures/rex-session-view.json` (the probe view captured from Rex, IDs kept, host/owner IDs replaced with zero UUIDs)
- Test: `Tests/BackendTerminal/RexWindowViewTests.swift`

**Interfaces:**
```swift
public struct RexControlView: Equatable, Sendable {
    public var revision: Int
    public var sessionID: String
    public var sessionLabel: String
    public var windows: [Window]
    public struct Window: Equatable, Sendable {
        public var id: String; public var label: String
        public var tree: TerminalSplitTree?   // nil when the tiled layer is empty
    }
    public var paneNames: [String: String]    // block ID → display name
    public static func decode(line: Data) throws -> RexControlMessage
}
public enum RexControlMessage: Equatable, Sendable {
    case view(RexControlView)
    case reply(id: Int, result: Data?, error: RexControlError?)
    case ended
}
public struct RexControlError: Error, Equatable, Sendable { public var code: String; public var message: String }
```
Mapping: only the first layer with `kind == "tiled"`; `split.direction` "vertical" → `.vertical`, anything else → `.horizontal`; `focused_block_id` → `focusedPaneID`; `zoomed_block_id` → `zoomedPaneID`; non-terminal blocks (creator not `com.superlogical.terminal`) still occupy their place but are named by label.

- [ ] Step 1: Failing tests: fixture decodes to the expected tree; unknown direction → horizontal; reply/ended lines; malformed line throws.
- [ ] Step 2: Implement; pass; commit `feat(rex): read window layouts from kwt rex control`.

### Task B3: One sidebar row per Rex window

**Files:**
- Modify: `Sources/BackendTerminal/RexInventory.swift` (summaries per window; `isWindowID`)
- Modify: `Sources/BackendTerminal/BackendTerminalAttachmentInfo.swift` (Rex attach validates block IDs via `isBlockID` still — panes keep using it)
- Modify: tests in `Tests/BackendTerminal/RexInventoryTests.swift` (existing file; find with `rg -l RexInventory Tests`)

**Interfaces:**
- Produces: Rex `BackendTerminalSummary` with `address == window_id` (`^window:[0-9A-Za-z-]+$`), `title` = window label unless it matches `^Window [0-9a-f]{8}$`, else the focused (or first) pane's name; `detail` = `"<session label> · N panes"` (`1 pane` singular).
- `RexInventory.isWindowID(_:)`.

- [ ] Step 1: Update failing tests for grouping, titles, details, duplicate window IDs rejected as malformed.
- [ ] Step 2: Implement; adjust callers that assumed a Rex address is a block (`rg "isBlockID" Sources`); commit `feat(rex): list Rex windows in the sidebar`.

### Task B4: Control channel process

**Files:**
- Create: `Sources/App/ProcessLineReader.swift` (move `SSHLeaseLineReader` and its helpers out of `KwtSSHLeaseClient.swift`, renamed `ProcessLineReader`; lease client uses it unchanged)
- Create: `Sources/App/RexControlChannel.swift`
- Test: `Tests/App/RexControlChannelTests.swift`

**Interfaces:**
```swift
@MainActor protocol RexControlChannelling: AnyObject {
    var onMessage: ((RexControlMessage) -> Void)? { get set }
    var onExit: ((RexControlChannelExit) -> Void)? { get set }
    func send(method: String, params: [String: any Sendable]) async throws -> Data?
    func stop()
}
enum RexControlChannelExit: Equatable { case ended, failed(String) }
@MainActor final class RexControlChannel: RexControlChannelling {
    init(command: [String], environment: [String: String]? = nil)  // argv; local or ssh built by caller
    func start() throws
}
```
- Command construction: local — the host's pinned kwt path from `BackendTerminalInventoryClient` executable resolution, run through `/bin/sh -c 'exec "$@"'`; SSH — the same argument shape as `BackendTerminalAttachmentInfo.sshArguments` but without `-tt` and with the remote command `<kwtPrelude> exec "$ghosthub_kwt_path" rex control 'WINDOW'`. Add `BackendTerminalAttachmentInfo.controlCommand(windowID:executablePath:sshConnectionArguments:)` beside `attachCommand` and test it there.
- Replies match by id; `send` throws `RexControlError` on an error reply and `CancellationError` when the channel stops.

- [ ] Step 1: Failing tests using a real process: a fake kwt shell script under the test's temp directory that prints a view line, echoes a reply for each request line (`read line; printf '{"type":"reply","id":%s,"result":{}}\n'`), and prints `{"type":"ended"}` on a trigger request. Assert `onMessage(.view)`, `send` returns, `onExit(.ended)`; killing the script yields `.failed`.
- [ ] Step 2: Failing tests for `controlCommand` strings (local and SSH; window ID quoted; invalid ID throws).
- [ ] Step 3: Implement; existing `KwtSSHLeaseClient` tests still pass; commit `feat(rex): run kwt rex control for an open window`.

### Task B5: Split container view

**Files:**
- Create: `Sources/Terminal/TerminalSplitContainerView.swift`
- Create: `Sources/Terminal/TerminalSplitPaneView.swift` (card + header + content host)
- Test: `Tests/Terminal/TerminalSplitContainerViewTests.swift` (XCTest; AppKit views off-window are fine for frames)

**Interfaces:**
```swift
@MainActor public protocol TerminalSplitPaneContent: AnyObject {
    var view: NSView { get }
    func setResizeDeferred(_ deferred: Bool)   // TerminalSurfaceView.setPresentationResizeDeferred
    func focus()
}
@MainActor public final class TerminalSplitContainerView: NSView {
    public struct Pane { public var id: String; public var title: String; public var overlayMessage: String?; public var content: TerminalSplitPaneContent }
    public var metrics = TerminalSplitMetrics()
    public var onResizeCommitted: ((TerminalSplitDivider, Double) -> Void)?
    public var onPaneClicked: ((String) -> Void)?
    public var onHeaderAction: ((String, TerminalSplitHeaderAction) -> Void)?
    public func apply(tree: TerminalSplitTree, panes: [Pane])
    public private(set) var paneViews: [String: TerminalSplitPaneView]  // for tests
}
public enum TerminalSplitHeaderAction: Equatable { case splitRight, splitDown, zoom, close }
```
Behavior: `apply` keeps `paneViews[id]` for surviving IDs (same object), creates new ones, removes gone ones, sets titles, then `needsLayout`. `layout()` assigns frames from `TerminalSplitLayout.frames` with `CATransaction.setDisableActions(true)`. Zoomed: other panes `isHidden = true`. Dividers: one tracking area per divider rect with `NSCursor.resizeLeftRight/UpDown`; `mouseDown` in a divider starts a drag: all contents `setResizeDeferred(true)`, `mouseDragged` updates `ratioOverrides[splitID]` (clamped) and relayouts; `mouseUp` → `setResizeDeferred(false)` on all, calls `onResizeCommitted(divider, ratio)` once, keeps the override until the next `apply` whose tree shows that ratio (avoids snap-back). Header: 24pt, title label, buttons only on the focused pane. A non-nil `overlayMessage` covers that pane's content with a small centered message (a pane whose attach failed); other panes are unaffected. Accessibility: each divider is an `NSAccessibilityElement` with role `.splitter`, label `"Divider between \(first) and \(second)"`, value = ratio.

- [ ] Step 1: Failing tests:
  - apply then re-apply with an extra pane keeps the original `paneViews` objects (identity `===`);
  - removed pane's view leaves the hierarchy;
  - frames after `layoutSubtreeIfNeeded()` equal `TerminalSplitLayout.frames` pane frames (+ header offset for content);
  - synthetic drag (mouseDown/Dragged×10/mouseUp via `NSEvent.mouseEvent`) on the root divider: recording contents see `setResizeDeferred(true)` before the first move, no `false` until mouseUp, then exactly one `onResizeCommitted` with ratio in range;
  - zoomed tree hides other panes, keeps them in `paneViews`.
- [ ] Step 2: Implement; pass; commit `feat(terminal): add a split container for terminal panes`.

### Task B6: Rex window presentation

**Files:**
- Create: `Sources/App/RexWindowPresentation.swift`
- Create: `Sources/App/RexWindowContentView.swift` (SwiftUI `NSViewRepresentable` hosting one container; overlay for channel-level disconnected state)
- Test: `Tests/App/RexWindowPresentationTests.swift`

**Interfaces:**
```swift
@MainActor final class RexWindowPresentation {
    let selection: WorkspaceBackendTerminalSelection   // address = window ID
    private(set) var tree: TerminalSplitTree?
    private(set) var paneHandles: [String: BorrowedBackendTerminalHandle]
    init(selection:, host: CommandHost, channel: any RexControlChannelling,
         coordinator: NativeBackendTerminalCoordinator, container: TerminalSplitContainerView)
    func split(_ direction: TerminalPaneSplitShortcut)      // new_split anchor focused, side after, focus true
    func focus(_ direction: RexFocusDirection)              // left/right/up/down/next/previous
    func toggleZoom()
    func closePane(_ blockID: String)                       // block.close (caller confirmed)
    func paneClicked(_ blockID: String)                     // focus_block
    func stop()                                             // channel.stop + coordinator.detach each pane
}
```
Behavior: on `.view`, find window by `selection.address`; missing → `onWindowClosed`. Attach new block IDs via `coordinator.attach(WorkspaceBackendTerminalSelection(hostID:, kind: .rex, address: blockID), host:)`; detach vanished. Build `TerminalSplitContainerView.Pane` with each handle's `coordinator.surface(handle:)` wrapped in a `TerminalSurfaceView` adapter conforming to `TerminalSplitPaneContent`. A pane whose handle reports `.disconnected(reason)` gets `overlayMessage = reason`. When `tree.focusedPaneID` differs from the previous view's, request keyboard focus on that pane. Resize commit → `session.resize_pane` with `before_block_id = divider.firstPaneID`, `after_block_id = divider.secondPaneID`, `direction`, `ratio`.

- [ ] Step 1: Failing tests with a `FakeRexControlChannel` (records `send` calls, lets the test deliver messages) and `RecordingNativeSessionSurfaceStore(viewPerSurface: true)`:
  - first view attaches one surface per block, tree matches;
  - second view with one more block attaches only that block (first views identical objects);
  - view without a block detaches it (surface removed key recorded);
  - `split(.right)` sends `session.new_split` with `anchor_id` = focused, `direction:"horizontal"`, `side:"after"`, `focus:true`, shell layout;
  - focus change in a later view requests keyboard focus on the new pane (recording surface `keyboardFocusRequestCount`);
  - resize commit sends one `session.resize_pane` with the right blocks and ratio;
  - window missing from a view calls `onWindowClosed`; `.ended` too.
- [ ] Step 2: Implement; pass; commit `feat(rex): show a Rex window as a split view`.

### Task B7: Scene wiring, shortcuts, session checks

**Files:**
- Modify: `Sources/App/WorkspaceSceneModel.swift` (open/close Rex windows through `RexWindowPresentation`; `borrowedBackendTerminalView` returns `RexWindowContentView` for `.rex`; `canSplitActivePane`/`splitActivePane` include the Rex window; session-check hold treats pane handles of the active Rex window as backend terminal handles)
- Modify: `Sources/App/WorkspaceSceneModel+Selection.swift` (new shortcut cases)
- Modify: `Sources/TerminalSupport/ApplicationShortcut.swift` (new actions: `focusPaneLeft/Right/Up/Down` default `cmd+opt+left/right/up/down`, `focusNextPane` `cmd+]`, `focusPreviousPane` `cmd+[`, `zoomPane` `cmd+shift+return`, group `.multiplexer`; each returns false when no Rex window is shown so the key reaches the terminal)
- Modify: `Sources/UI/CommandPaletteModel.swift` (Close Pane… for the focused Rex pane; confirmation sheet using the existing kill-confirmation pattern — find with `rg -n "confirm" Sources/UI/*Kill*`)
- Test: `Tests/App/WorkspaceRexWindowTests.swift`

- [ ] Step 1: Failing tests: opening a Rex window row starts the channel (fake channel factory injected through `WorkspaceSceneModel` init like other providers) and shows its panes; ⌘D routes to `new_split` only while the Rex window is active; focus shortcuts return false otherwise; Close Pane requires confirmation then sends `block.close`; ⌘W closes the view and stops the channel without `block.close`; a Herdr open during a Rex window holds every pane's input (reuse `SessionCheckHold.backendTerminals`).
- [ ] Step 2: Implement; full `make swift-test`; commit `feat(rex): open Rex windows, split shortcuts, and pane commands`.

### Task B8: Pin kwt, docs, real-app check, PR

**Files:**
- Modify: `KWT_REVISION` (after kwt PR merges; follow `docs` instructions for updating the pinned kwt — find with `rg -l KWT_REVISION docs scripts`)
- Modify: `AGENTS.md` (layout rule: Rex layout drawn from Rex's view, never invented), `docs/architecture.md`, `docs/terminal-sessions.md` (Rex window rows, control channel, split view behavior, ⌘W, known size limit)

- [ ] Step 1: Update pin and docs; commit `docs(rex): describe Rex window split views` with the pin in its own commit.
- [ ] Step 2: Real check with a debug build against the local Rex server: throwaway session with 3 panes; open in Ghosthub; ⌘D, ⇧⌘D, drag divider (no resize events until mouse-up via `rex events -s`), focus shortcuts, zoom, Close Pane, edit layout in Rex CLI and see Ghosthub follow; delete the session.
- [ ] Step 3: Full suite, private-terms scan, push, open PR with pr-desc; report CI as pending.
