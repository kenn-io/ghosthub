# Native Active-Pane Find Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Ghostty-style Find bar that searches the complete active tmux pane history and delegates standalone terminal search to libghostty.

**Architecture:** Every terminal surface exposes one `TerminalFindController` from `GhosthubTerminalSupport`. The controller owns bar state, debounce/coalescing, and one serial backend lane. Ordinary libghostty surfaces install an in-process backend, supported POSIX tmux surfaces replace it with an exact-client-fenced tmux backend, and Herdr, Zellij, psmux, and unsupported tmux versions replace it with an unavailable controller.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing, XCTest for libghostty smoke coverage, tmux 3.4+, `ghostty_surface_binding_action`, and the existing local/SSH command runners.

## Global Constraints

- Search, match highlighting, viewport movement, and history remain backend-owned; no pane text or match snippet enters Swift.
- POSIX tmux 3.4 is the minimum supported tmux Find version.
- tmux 3.4 or newer and older than 3.6 renders `search-backward-text <query>`; tmux 3.6 and newer renders `search-backward-text -- <query>`.
- Exact totals are available only on tmux 3.5 and newer, and only when `search_count_partial` is exactly `0`.
- Every tmux mutation is fenced to the frozen server, client, session, and pane identity through the existing client-specific refresh hook mechanism.
- Every nested command token reuses `shellQuotedCommandArgument`; do not introduce a second quoting encoder.
- Find Next sends tmux `search-again`; Find Previous sends `search-reverse`. Do not normalize tmux's mode-key-dependent first step after a direction change.
- Herdr, Zellij, psmux, and tmux older than 3.4 remain explicitly unavailable. Do not add fallbacks or inject configurable key sequences.
- Queries are never logged, persisted, included in diagnostics, or requested through `search_match`.
- Preview surfaces never expose Find. Parking or replacing a surface closes its active Find session first.
- New tests cover Ghosthub-owned state, rendering, fencing, and integration seams. They do not assert configurable tmux wrapping or emacs/vi direction-flip behavior.
- Real-tmux tests use `TestTmuxServer` and run through `tools/run_swift_tests.sh` via `make swift-test`.
- Keep both bootstrapped and unbootstrapped `GhosthubTerminal` targets compiling.
- This plan and its design spec are local working artifacts. Remove `docs/superpowers/specs/` and `docs/superpowers/plans/` before any push or pull request.

---

## File Structure

### New files

- `Sources/TerminalSupport/TerminalFindController.swift` — backend-neutral Find state, synchronous-result/callback-pending backend replies, serial latest-value-wins operation lane, and public controller API.
- `Tests/TerminalSupport/TerminalFindControllerTests.swift` — controller state, debounce, coalescing, stale-result, no-match, and close behavior.
- `Sources/App/TmuxAttachedClientGuard.swift` — generic exact-client identity and guarded-hook command renderer extracted from pane splitting.
- `Sources/App/TmuxVersion.swift` — one numeric tmux major/minor parser used by discovery, pane split capability, and Find rendering.
- `Sources/App/TmuxPaneFinder.swift` — versioned tmux Find command construction, state marker parsing, execution, and query-free failures.
- `Tests/App/TmuxPaneFinderTests.swift` — command rendering, state parsing, exact-client fencing, literal query, and real-tmux behavior.
- `Sources/Terminal/LibghosttyFind.swift` — libghostty backend actions and callback-to-controller bridge.
- `Sources/TerminalUnavailable/LibghosttyFind.swift` — unavailable-build controller factory with the same public surface contract.
- `Tests/TerminalSmoke/LibghosttyFindSmokeTests.swift` — live libghostty search, navigation, callback, close, and teardown behavior.
- `Sources/App/TerminalFindBar.swift` — compact SwiftUI bar and AppKit search field for Return, Shift-Return, Escape, focus, and selection.
- `Tests/App/TerminalFindBarTests.swift` — status text, button availability, and field-command mapping.

### Existing files changed

- `Sources/TerminalSupport/ApplicationShortcut.swift` and `Tests/TerminalSupport/ApplicationShortcutTests.swift` — four configurable Find catalog actions and Ghostty-compatible defaults.
- `Sources/Terminal/TerminalSurfaceView.swift`, `Sources/Terminal/TerminalSurfaceCoordinator.swift`, and `Sources/TerminalUnavailable/TerminalSurfaceStubs.swift` — per-surface controller ownership, parking cleanup, and unavailable-build parity.
- `Sources/Terminal/LibghosttyRuntime.swift` — handle start/end/total/selected search callbacks for the originating surface.
- `Sources/App/TmuxPaneSplitter.swift` and `Tests/App/TmuxPaneSplitterTests.swift` — consume the extracted client identity, version, and guard without changing pane-split behavior.
- `Sources/App/TmuxBinaryResolver.swift` and `Tests/App/TmuxBinaryResolverTests.swift` — consume the shared tmux version parser.
- `Sources/App/NativeSessionAttachmentSupport.swift`, `Sources/App/NativeTmuxSessionCoordinator.swift`, `Sources/App/NativeHerdrSessionCoordinator.swift`, and `Sources/App/NativeZellijSessionCoordinator.swift` — surface controller assignment, tmux frozen target creation, lifecycle cleanup, and unsupported-backend gating.
- `Sources/App/WorkspaceSceneModel.swift`, `Sources/App/WorkspaceSceneModel+Selection.swift`, `Sources/App/MenuCommands.swift`, and `Sources/App/App.swift` — active-controller routing and Edit menu commands.
- `Sources/App/BorrowedTmuxSessionView.swift`, `Sources/App/BorrowedHerdrSessionView.swift`, `Sources/App/BorrowedZellijSessionView.swift`, the renamed `Sources/App/NativeTerminalOperationErrorOverlay.swift`, and affected tests/stubs — Find overlay hosting plus generic terminal-operation error naming.
- `docs/architecture.md`, `docs/terminal-sessions.md`, `website/docs/content/keyboard-shortcuts.md`, and `website/docs/content/sessions.md` — ownership, support, shortcuts, wrapping, and multi-client behavior.
- `website/demo/assets/demohost.m`, `website/demo/shoot.sh`, and `tools/tests/test_demo_scripts.py` — deterministic Find-bar capture state for `guide-find.png`.

---

### Task 1: Shared Find Controller and Shortcut Catalog

**Files:**
- Create: `Sources/TerminalSupport/TerminalFindController.swift`
- Create: `Tests/TerminalSupport/TerminalFindControllerTests.swift`
- Modify: `Sources/TerminalSupport/ApplicationShortcut.swift:3-22,330-380`
- Modify: `Tests/TerminalSupport/ApplicationShortcutTests.swift:35-80`
- Modify: `Tests/Settings/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `TerminalFindDirection`, `TerminalFindResult`, `TerminalFindBackendResponse`, `TerminalFindFailure`, `TerminalFindSession`, and `@MainActor TerminalFindController`.
- Produces controller methods: `open()`, `updateQuery(_:)`, `findNext()`, `findPrevious()`, `close()`, `backendDidOpen(query:)`, `backendDidEnd()`, and `publishBackendResult(total:selected:)`.
- Produces shortcut actions: `.find`, `.findNext`, `.findPrevious`, and `.hideFindBar`.

- [ ] **Step 1: Add failing catalog tests for the four commands**

Extend the existing expected-default dictionary with:

```swift
.find: "cmd+f",
.findNext: "cmd+g",
.findPrevious: "cmd+shift+g",
.hideFindBar: "cmd+shift+f",
```

Also assert the titles are `Find…`, `Find Next`, `Find Previous`, and `Hide Find Bar`, and that all four belong to the `.application` settings group.

- [ ] **Step 2: Run the catalog tests and verify the new enum cases are missing**

Run: `make swift-test SWIFT_TEST_FILTER=ApplicationShortcutTests`

Expected: FAIL because the four `ApplicationShortcutAction` cases do not exist.

- [ ] **Step 3: Add the shortcut cases and catalog definitions**

Add these cases to `ApplicationShortcutAction`:

```swift
case find = "find"
case findNext = "find-next"
case findPrevious = "find-previous"
case hideFindBar = "hide-find-bar"
```

Add these definitions after the application navigation commands:

```swift
definition(.find, "Find…", .application, "cmd+f"),
definition(.findNext, "Find Next", .application, "cmd+g", repeats: true),
definition(
    .findPrevious,
    "Find Previous",
    .application,
    "cmd+shift+g",
    repeats: true
),
definition(.hideFindBar, "Hide Find Bar", .application, "cmd+shift+f"),
```

- [ ] **Step 4: Write controller tests before the controller**

Cover these owned state transitions with a recording `TerminalFindSession`:

Implement these four tests with a controllable `FindSessionRecorder` in the same test file:

1. `latestQueryWins`: block search `n`, submit `ne` and `needle`, release the first search, wait for two searches, and assert the recorder saw exactly `["n", "needle"]`, the controller query is `needle`, and maximum concurrent operations is one.
2. `staleCompletionIsIgnored`: return `.result(.match(total: 1, selected: nil))` for a blocked first generation, submit a second query that returns `.result(.match(total: 2, selected: nil))`, release both in order, and assert the visible result is the second generation's total.
3. `noMatchDisablesNavigation`: return `.result(.noMatch)`, wait for `canNavigate == false`, call both navigation methods, drain the lane, and assert the recorder received no navigation requests.
4. `closeEndsSession`: block the first search, call `close()`, release the search, wait for the close request, and assert `isOpen == false`, `result == .idle`, exactly one backend close occurred, and the stale search result did not publish.

Add a fifth callback-pending test: return `.awaitingCallback`, assert `isWorking` remains true, call `publishBackendResult(total:selected:)`, and assert the callback result clears `isWorking` and becomes visible. `FindSessionRecorder` records the maximum simultaneous call count so every test can also prove the lane never runs two backend operations concurrently.

- [ ] **Step 5: Run the controller tests and verify the type is missing**

Run: `make swift-test SWIFT_TEST_FILTER=TerminalFindControllerTests`

Expected: FAIL because `TerminalFindController` and its backend types do not exist.

- [ ] **Step 6: Implement the shared types and controller lane**

Use this public contract:

```swift
public enum TerminalFindDirection: Equatable, Sendable {
    case next
    case previous
}

public enum TerminalFindResult: Equatable, Sendable {
    case idle
    case match(total: UInt?, selected: UInt?)
    case noMatch
}

public enum TerminalFindBackendResponse: Equatable, Sendable {
    case result(TerminalFindResult)
    case awaitingCallback
}

public struct TerminalFindFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct TerminalFindSession: Sendable {
    public let search:
        @Sendable (String) async
        -> Result<TerminalFindBackendResponse, TerminalFindFailure>
    public let navigate:
        @Sendable (TerminalFindDirection) async
        -> Result<TerminalFindBackendResponse, TerminalFindFailure>
    public let close: @Sendable () async -> TerminalFindFailure?
}

@MainActor
public final class TerminalFindController: ObservableObject {
    @Published public private(set) var isOpen = false
    @Published public private(set) var query = ""
    @Published public private(set) var result: TerminalFindResult = .idle
    @Published public private(set) var isWorking = false
    @Published public private(set) var failureMessage: String?
    @Published public private(set) var fieldSelectionRevision: UInt64 = 0

    public let isAvailable: Bool

    public init(
        isAvailable: Bool,
        debounce: Duration = .milliseconds(150),
        sessionProvider: @escaping @MainActor @Sendable ()
            -> TerminalFindSession?
    )

    public static var unavailable: TerminalFindController { get }
    public var canNavigate: Bool { get }
    public func open()
    public func updateQuery(_ value: String)
    public func findNext()
    public func findPrevious()
    public func close()
    public func backendDidOpen(query: String)
    public func backendDidEnd()
    public func publishBackendResult(total: Int, selected: Int?)
}
```

Import `Combine` for `ObservableObject` and `@Published`. Keep one `workerTask`, one optional debounced query, and one pending action queue. A new query removes queued navigation and replaces any queued query. Closing immediately hides the bar and invalidates publication, but enqueues exactly one backend close behind an already-running operation. Each operation captures a session UUID and query generation; publish only while both still match. A `.result` reply completes work synchronously. For `.awaitingCallback`, compare a private callback revision captured immediately before invoking the backend with the revision after it returns: keep `isWorking` true only when they still match; otherwise the synchronous callback already completed the request. Every accepted `backendDidOpen`, `backendDidEnd`, or `publishBackendResult` call increments that revision. Map a negative libghostty total to `.idle`, zero to `.noMatch`, and a positive total to `.match(total:selected:)` after converting the zero-based selected callback to a one-based value.

- [ ] **Step 7: Run the focused tests**

Run: `make swift-test SWIFT_TEST_FILTER='ApplicationShortcutTests|TerminalFindControllerTests|SettingsStoreTests'`

Expected: PASS with the new actions round-tripping through compiled defaults and persisted overrides, and all controller operations reporting a maximum concurrency of one.

- [ ] **Step 8: Commit the shared contract**

```bash
git add Sources/TerminalSupport/TerminalFindController.swift Sources/TerminalSupport/ApplicationShortcut.swift Tests/TerminalSupport/TerminalFindControllerTests.swift Tests/TerminalSupport/ApplicationShortcutTests.swift Tests/Settings/SettingsStoreTests.swift
git commit -m "Add shared terminal Find state"
```

---

### Task 2: Extract the Reusable tmux Version and Exact-Client Guard

**Files:**
- Create: `Sources/App/TmuxVersion.swift`
- Create: `Sources/App/TmuxAttachedClientGuard.swift`
- Modify: `Sources/App/TmuxPaneSplitter.swift:1-105,263-421`
- Modify: `Sources/App/TmuxBinaryResolver.swift:619-642`
- Modify: `Sources/App/NativeTmuxSessionCoordinator.swift`
- Modify: `Tests/App/TmuxPaneSplitterTests.swift`
- Modify: `Tests/App/TmuxBinaryResolverTests.swift`

**Interfaces:**
- Produces: `TmuxVersion.init?(output:)`, `.minimumFind`, `.copyModeOptionParsing`, and `.searchCount` comparison constants.
- Produces: `TmuxAttachedClientIdentity`, `TmuxAttachedClientGuard.command(...)`, and `TmuxAttachedClientGuard.cleanupCommand(...)`.
- Preserves: pane split, sizing, client lookup, marker checking, and all existing failure text.

- [ ] **Step 1: Add failing version and guard-equivalence tests**

Add parameterized cases that prove suffixes do not affect numeric comparison:

```swift
@Test(arguments: [
    ("tmux 3.4", 3, 4),
    ("tmux 3.5a", 3, 5),
    ("tmux 3.5b", 3, 5),
    ("tmux 3.6", 3, 6),
    ("tmux 4.0", 4, 0),
])
func parsesTmuxVersion(_ output: String, _ major: Int, _ minor: Int) {
    #expect(TmuxVersion(output: output) == TmuxVersion(major: major, minor: minor))
}
```

Move the existing command assertions for marker validation, exact TTY, client PID/creation, pane ID, and cleanup into assertions against the extracted guard. Retain one pane-split command test to prove its observable rendering is unchanged.

- [ ] **Step 2: Run the focused tests and verify the new types are missing**

Run: `make swift-test SWIFT_TEST_FILTER='TmuxPaneSplitterTests|TmuxBinaryResolverTests'`

Expected: FAIL because `TmuxVersion` and `TmuxAttachedClientGuard` do not exist.

- [ ] **Step 3: Implement the numeric version value**

```swift
struct TmuxVersion: Comparable, Equatable, Sendable {
    static let minimumFind = Self(major: 3, minor: 4)
    static let searchCount = Self(major: 3, minor: 5)
    static let copyModeOptionParsing = Self(major: 3, minor: 6)

    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(output: String) {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "tmux" else { return nil }
        let components = fields[1].split(separator: ".", maxSplits: 1)
        guard components.count == 2,
              let major = Int(components[0]),
              let minor = Int(components[1].prefix(while: \.isNumber))
        else { return nil }
        self.init(major: major, minor: minor)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}
```

Change `TmuxPaneSplitter.supportsPaneSplitting` and `TmuxBinaryResolver.isSupported` to use this parser. Do not keep the old private parsers as fallbacks.

- [ ] **Step 4: Extract the identity and guarded queue renderer**

Rename `TmuxPaneSplitClientIdentity` to `TmuxAttachedClientIdentity`. Move the hook wrapper and cleanup rendering into `TmuxAttachedClientGuard` with this entry point:

```swift
static func command(
    tmuxPath: String,
    socketName: String?,
    expectedClient: TmuxAttachedClientIdentity,
    marker: String,
    hookIndex: Int,
    action: String
) -> String
```

`action` is a fully rendered child tmux command string. The guard must validate server/session identity, exact client PID/creation/TTY, pane ID, and `hook_argument_0`, run `action` only on success, print the mismatch marker otherwise, and remove the uniquely indexed hook both in the queue and in shell cleanup. Pass the complete child string through `shellQuotedCommandArgument` before placing it in its parent token, and repeat that rule at every enclosing tmux depth.

- [ ] **Step 5: Point pane split and sizing at the extracted guard**

Replace their local hook construction with `TmuxAttachedClientGuard.command(...)`. Keep split-specific marker names and mutation bodies in `TmuxPaneSplitter`. Do not change runner, cancellation, retry, or error behavior.

- [ ] **Step 6: Run the focused tests**

Run: `make swift-test SWIFT_TEST_FILTER='TmuxPaneSplitterTests|TmuxBinaryResolverTests|NativeTmuxSessionCoordinatorTests'`

Expected: PASS, including the existing real-tmux exact-client tests.

- [ ] **Step 7: Commit the reusable tmux seam**

```bash
git add Sources/App/TmuxVersion.swift Sources/App/TmuxAttachedClientGuard.swift Sources/App/TmuxPaneSplitter.swift Sources/App/TmuxBinaryResolver.swift Sources/App/NativeTmuxSessionCoordinator.swift Tests/App/TmuxPaneSplitterTests.swift Tests/App/TmuxBinaryResolverTests.swift Tests/App/NativeTmuxSessionCoordinatorTests.swift
git commit -m "Share the guarded tmux client boundary"
```

---

### Task 3: Implement the tmux Find Executor

**Files:**
- Create: `Sources/App/TmuxPaneFinder.swift`
- Create: `Tests/App/TmuxPaneFinderTests.swift`
- Modify: `Tests/App/TmuxPaneSplitterTests.swift` only if shared real-client helpers move to file scope

**Interfaces:**
- Consumes: `TmuxVersion`, `TmuxAttachedClientIdentity`, `TmuxAttachedClientGuard`, `shellQuotedCommandArgument`, `CommandHost`, and the existing account command runner.
- Produces: `TmuxFindTarget`, `TmuxFindMutation`, `TmuxFindState`, `TmuxFindFailure`, and `TmuxPaneFinder.perform(_:target:)`.

- [ ] **Step 1: Write state-parser and version-rendering tests**

Use a fixed marker token and cover:

```swift
#expect(TmuxPaneFinder.parseState(
    "noise\nGHOSTHUB_TMUX_FIND_STATE_token\t1\t5\t0\nwarning",
    marker: "GHOSTHUB_TMUX_FIND_STATE_token",
    includesCount: true
) == .match(total: 5))

#expect(TmuxPaneFinder.parseState(
    "GHOSTHUB_TMUX_FIND_STATE_token\t0\t\t",
    marker: "GHOSTHUB_TMUX_FIND_STATE_token",
    includesCount: true
) == .noMatch)
```

Reject an absent marker, malformed `search_present`, extra fields, partial counts, and any line whose marker token differs. Assert that a 3.5b target omits `--`, a 3.6 target includes `--`, and both preserve `-foo` as one query argument.

- [ ] **Step 2: Add literal-data and no-leak command tests**

Render the query:

```text
match;"x" #{pane_id} \ q't $HOME ${x} -lead
```

Run `/bin/sh -n -c <rendered command>`, assert success, and inspect the innermost decoded mutation through a recording runner. Assert that the state format requests only `search_present`, `search_count`, and `search_count_partial`; never request `search_match`. Do not assert the query's absence from the command itself—it must be present there as data. Assert instead that `TmuxFindFailure.message` is one of the fixed query-free messages.

- [ ] **Step 3: Run the tests and verify the executor is missing**

Run: `make swift-test SWIFT_TEST_FILTER=TmuxPaneFinderTests`

Expected: FAIL because `TmuxPaneFinder` does not exist.

- [ ] **Step 4: Implement the executor types**

```swift
struct TmuxFindTarget: Sendable {
    let host: CommandHost
    let tmuxPath: String
    let tmuxVersion: TmuxVersion
    let sessionName: String
    let socketName: String?
    let sshConnectionArguments: [String]
    let expectedClient: TmuxAttachedClientIdentity
}

enum TmuxFindMutation: Equatable, Sendable {
    case search(String)
    case next
    case previous
    case cancel
}

enum TmuxFindState: Equatable, Sendable {
    case match(total: UInt?)
    case noMatch
}

struct TmuxFindFailure: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case targetChanged
        case transport
        case command
        case malformedState
    }

    let kind: Kind
    let status: Int32
    let message: String
}
```

`TmuxPaneFinder.perform` returns `Result<TmuxFindState?, TmuxFindFailure>`; cancel succeeds with `nil` state.

- [ ] **Step 5: Render each mutation inside one guarded queue**

For `.search(query)`, render this mutation body from individual quoted tokens:

```text
copy-mode -t <pane> ;
send-keys -t <pane> -X history-bottom ;
send-keys -t <pane> -X search-backward-text [-- for >=3.6] <query> ;
display-message -p -t <pane> <marked state format>
```

For `.next`, use `search-again`; for `.previous`, use `search-reverse`; for `.cancel`, use `cancel` and omit the state read. On 3.4, the format has marker plus `search_present`. On 3.5+, append `search_count` and `search_count_partial`. Wrap the complete action with `TmuxAttachedClientGuard.command` so the query crosses exactly three single-quoted tmux parser layers and one account-shell layer.

- [ ] **Step 6: Parse only the marked state and map failures without raw diagnostics**

Map a guard mismatch or missing client to `The attached tmux session changed.` Map nonzero transport-classified failures to `Find lost its connection to tmux.` Map other nonzero statuses to `tmux could not search this pane.` Map a successful command without one valid marked state line to `tmux returned an invalid Find result.` Never place `runner.diagnostic` or the rendered command in `TmuxFindFailure.message`.

- [ ] **Step 7: Add real-tmux integration coverage**

Using `TestTmuxServer` plus the existing `TestTmuxClient` pattern, create scrollback with three literal matches and verify:

- the initial search selects the newest match;
- repeated `next` requests establish and progress in the older direction;
- repeated `previous` requests establish and progress in the newer direction;
- no-match returns `.noMatch` while copy mode remains active;
- cancel exits copy mode;
- punctuation and the full literal-data query survive the guarded command;
- replacing the session or changing the pane causes no mutation and returns `targetChanged`;
- two attached clients observe the same pane-wide copy mode, and another client's cancel makes later navigation fail soft.

Do not assert that the first request after a direction flip must move to another match.

- [ ] **Step 8: Run the executor suite through the owned tmux harness**

Run: `make swift-test SWIFT_TEST_FILTER=TmuxPaneFinderTests`

Expected: PASS on the installed tmux, with `tools/run_swift_tests.sh` creating and cleaning the private server root.

- [ ] **Step 9: Commit the tmux executor**

```bash
git add Sources/App/TmuxPaneFinder.swift Tests/App/TmuxPaneFinderTests.swift Tests/App/TmuxPaneSplitterTests.swift
git commit -m "Search exact tmux pane history"
```

---

### Task 4: Install Per-Surface Controllers in Native Session Coordinators

**Files:**
- Modify: `Sources/Terminal/TerminalSurfaceView.swift:85-190,606-629`
- Modify: `Sources/TerminalUnavailable/TerminalSurfaceStubs.swift:80-150`
- Modify: `Sources/App/NativeSessionAttachmentSupport.swift:7-55`
- Modify: `Sources/App/NativeTmuxSessionCoordinator.swift:80-190,430-470,760-930,943-1235,1430-1460`
- Modify: `Sources/App/NativeHerdrSessionCoordinator.swift:392-450`
- Modify: `Sources/App/NativeZellijSessionCoordinator.swift:319-370`
- Move: `Sources/App/NativePaneSplitErrorOverlay.swift` to `Sources/App/NativeTerminalOperationErrorOverlay.swift`
- Modify: `Sources/App/BorrowedTmuxSessionView.swift:241-280`
- Modify: `Sources/App/BorrowedHerdrSessionView.swift:174-215`
- Modify: affected stubs and coordinator tests in `Tests/App/`

**Interfaces:**
- Consumes: shared controller and `TmuxPaneFinder`.
- Produces: `NativeSessionPaneSurfacing.terminalFindController` and `terminalOperationErrorMessage`.
- Produces: `NativeTmuxSessionCoordinator.findController(_:)` for the active scene.

- [ ] **Step 1: Write coordinator availability and frozen-target tests**

Add tests for these observable transitions:

- tmux 3.3 surface controller is unavailable;
- tmux 3.4 surface controller becomes available only after exact-client binding;
- tmux Find reuses the attachment's frozen tmux path, socket, host, SSH argument snapshot, version, and client identity;
- a replacement attachment closes the old controller and cannot publish its result;
- Herdr and Zellij surfaces expose unavailable controllers even though their libghostty client buffers contain rendered output;
- preview parking closes an open controller before `isParkedForPreview` becomes true.

- [ ] **Step 2: Run the coordinator tests and verify they fail**

Run: `make swift-test SWIFT_TEST_FILTER='NativeTmuxSessionCoordinatorTests|NativeHerdrSessionCoordinatorTests|NativeZellijSessionCoordinatorTests|TerminalSurfacePreviewTests'`

Expected: FAIL because surfaces do not expose a Find controller.

- [ ] **Step 3: Add controller ownership to the surface protocol and both terminal targets**

Add this requirement:

```swift
var terminalFindController: TerminalFindController { get set }
```

The real and unavailable `TerminalSurfaceView` types initialize it to `.unavailable`. In `setParkedForPreview(true)`, call `terminalFindController.close()` before changing focus or parking state.

- [ ] **Step 4: Generalize the terminal error presentation names**

Rename:

```text
paneSplitErrorMessage                 -> terminalOperationErrorMessage
NativePaneSplitErrorOverlay           -> NativeTerminalOperationErrorOverlay
PaneSplitErrorDismissal               -> TerminalOperationErrorDismissal
presentPaneSplitError / clear...       -> presentTerminalOperationError / clear...
```

Keep pane-split behavior and tests unchanged apart from names. Find failures set the same surface message, but only from `TmuxFindFailure.message`; never pass `TmuxPaneSplitter.normalizedDiagnostic`, finder raw output, or a rendered query command.

- [ ] **Step 5: Store tmux version and finder in the coordinator**

Add `tmuxVersion: TmuxVersion` to `NativeTmuxAttachment`, derived from the already resolved binary version. Inject `TmuxPaneFinder` beside `TmuxPaneSplitter`. After exact-client binding succeeds, install a new `TerminalFindController` whose `sessionProvider` captures a value-only `TmuxFindTarget` for that attachment ID. Convert finder results as follows:

```swift
.success(.match(let total)) -> .success(.result(.match(total: total, selected: nil)))
.success(.noMatch)          -> .success(.result(.noMatch))
.success(nil)               -> .success(.result(.idle))
.failure(let failure)       -> .failure(.init(message: failure.message))
```

On close, detach, reconnect, session replacement, pane identity change, or coordinator shutdown, close the controller before removing the surface or attachment. A failed identity guard closes the bar and presents the fixed failure for four seconds.

- [ ] **Step 6: Disable Find explicitly for unsupported native backends**

Immediately after creating Herdr and Zellij surfaces, assign `.unavailable`. Do the same for psmux/Windows and tmux older than 3.4. This override is mandatory even after Task 5 makes ordinary libghostty surfaces searchable.

- [ ] **Step 7: Run the focused coordinator and preview suites**

Run: `make swift-test SWIFT_TEST_FILTER='NativeTmuxSessionCoordinatorTests|NativeHerdrSessionCoordinatorTests|NativeZellijSessionCoordinatorTests|TerminalSurfacePreviewTests|TmuxPaneFinderTests'`

Expected: PASS with no query text in recorded logs or terminal-operation messages.

- [ ] **Step 8: Commit native attachment integration**

```bash
git add Sources/Terminal/TerminalSurfaceView.swift Sources/TerminalUnavailable/TerminalSurfaceStubs.swift Sources/App/NativeSessionAttachmentSupport.swift Sources/App/NativeTmuxSessionCoordinator.swift Sources/App/NativeHerdrSessionCoordinator.swift Sources/App/NativeZellijSessionCoordinator.swift Sources/App/NativePaneSplitErrorOverlay.swift Sources/App/NativeTerminalOperationErrorOverlay.swift Sources/App/BorrowedTmuxSessionView.swift Sources/App/BorrowedHerdrSessionView.swift Sources/App/BorrowedZellijSessionView.swift Tests/App/NativeTmuxSessionCoordinatorTests.swift Tests/App/NativeHerdrSessionCoordinatorTests.swift Tests/App/NativeZellijSessionCoordinatorTests.swift Tests/App/BorrowedTmuxSessionViewTests.swift Tests/App/BorrowedHerdrSessionViewTests.swift Tests/App/BorrowedZellijSessionViewTests.swift Tests/TerminalSmoke/TerminalSurfacePreviewTests.swift
git commit -m "Bind Find to native terminal surfaces"
```

---

### Task 5: Bridge Standalone Surfaces to libghostty Search

**Files:**
- Create: `Sources/Terminal/LibghosttyFind.swift`
- Create: `Sources/TerminalUnavailable/LibghosttyFind.swift`
- Create: `Tests/TerminalSmoke/LibghosttyFindSmokeTests.swift`
- Modify: `Sources/Terminal/TerminalSurfaceCoordinator.swift:20-70`
- Modify: `Sources/Terminal/LibghosttyRuntime.swift:814-1010`
- Modify: `Sources/Terminal/TerminalSurfaceView.swift`
- Modify: `Sources/TerminalUnavailable/TerminalSurfaceStubs.swift`

**Interfaces:**
- Consumes: `TerminalFindController` and libghostty action callbacks.
- Produces: `TerminalSurfaceView.installLibghosttyFindController()` and surface-routed callback publication.

- [ ] **Step 1: Write live libghostty smoke tests**

Create an owned `TerminalSurfaceView`, host it in a test window, inject deterministic output with repeated `needle` lines, then verify:

```swift
let controller = view.terminalFindController
controller.open()
controller.updateQuery("needle")
await waitUntil { controller.result == .match(total: 3, selected: 1) }
controller.findNext()
await waitUntil { controller.result == .match(total: 3, selected: 2) }
controller.close()
await waitUntil { !controller.isOpen && controller.result == .idle }
```

Also invoke synthetic `START_SEARCH`, `SEARCH_TOTAL`, `SEARCH_SELECTED`, and `END_SEARCH` actions through `LibghosttyRuntime.handleAction` and assert they update only the target surface. Every test must retain the surface through teardown and `await view.shutdown()` before the worker exits.

- [ ] **Step 2: Run the smoke suite and verify standalone Find is unavailable**

Run: `make swift-test SWIFT_TEST_FILTER=LibghosttyFindSmokeTests`

Expected: FAIL because ordinary surfaces still use `.unavailable`.

- [ ] **Step 3: Implement libghostty binding actions**

Build a `TerminalFindSession` for each ordinary surface:

```swift
search: { [weak view] query in
    guard let view,
          view.performBindingAction("search:\(query)")
    else {
        return .failure(.init(message: "The terminal could not start Find."))
    }
    return .success(.awaitingCallback)
},
navigate: { [weak view] direction in
    let action = direction == .next
        ? "navigate_search:next"
        : "navigate_search:previous"
    guard let view, view.performBindingAction(action) else {
        return .failure(.init(message: "The terminal could not navigate Find."))
    }
    return .success(.awaitingCallback)
},
close: { [weak view] in
    guard let view else { return nil }
    _ = view.performBindingAction("end_search")
    return nil
}
```

The callback bridge remains authoritative for total and selected values. `.awaitingCallback` keeps the current result visible and the request working until the originating surface publishes a total/selection callback or ends search. The controller's before/after callback revision check treats a callback delivered synchronously during `performBindingAction` as the completion, so the later `.awaitingCallback` return cannot overwrite it or leave `isWorking` set.

- [ ] **Step 4: Handle and copy all four callback payloads**

In `LibghosttyRuntime.handleAction`:

- copy `start_search.needle` to `String` before dispatch and call `backendDidOpen(query:)` on the originating surface;
- call `backendDidEnd()` for `END_SEARCH`;
- pass `search_total.total` to `publishBackendResult(total:selected:)`;
- pass `search_selected.selected` while retaining the most recent total on that surface.

Treat negative totals and selected values as libghostty's absent-value sentinel. Never read callback payload pointers after the async dispatch.

- [ ] **Step 5: Install the backend only on libghostty-owned surfaces**

`TerminalSurfaceCoordinator.surface(for:configuration:)` calls `installLibghosttyFindController()` after constructing a new ordinary surface. Native tmux, Herdr, and Zellij coordinators still replace the controller as defined in Task 4. The unavailable target's method installs `.unavailable` and performs no binding action.

- [ ] **Step 6: Run terminal regression checks for the bridge**

Run:

```bash
make test-libghostty-bootstrap
make swift-test SWIFT_TEST_FILTER='LibghosttyFindSmokeTests|LibghosttyRuntimeSmokeTests|TerminalShortcutReservationTests'
```

Expected: PASS, with every created surface shut down and no surviving shell process.

- [ ] **Step 7: Commit the libghostty backend**

```bash
git add Sources/Terminal/LibghosttyFind.swift Sources/TerminalUnavailable/LibghosttyFind.swift Sources/Terminal/TerminalSurfaceCoordinator.swift Sources/Terminal/LibghosttyRuntime.swift Sources/Terminal/TerminalSurfaceView.swift Sources/TerminalUnavailable/TerminalSurfaceStubs.swift Tests/TerminalSmoke/LibghosttyFindSmokeTests.swift
git commit -m "Drive standalone Find through libghostty"
```

---

### Task 6: Add Edit Menu Routing and the Ghostty-Style Find Bar

**Files:**
- Create: `Sources/App/TerminalFindBar.swift`
- Create: `Tests/App/TerminalFindBarTests.swift`
- Modify: `Sources/App/WorkspaceWindow.swift:8-40`
- Modify: `Sources/App/MenuCommands.swift:1-75`
- Modify: `Sources/App/App.swift:190-235,300-350`
- Modify: `Sources/App/WorkspaceSceneModel.swift:640-690,7558-7635`
- Modify: `Sources/App/WorkspaceSceneModel+Selection.swift:45-130`
- Modify: `Sources/App/BorrowedTmuxSessionView.swift:241-285`
- Modify: `Sources/App/BorrowedHerdrSessionView.swift:174-220`
- Modify: `Sources/App/BorrowedZellijSessionView.swift:169-215`
- Modify: `Tests/App/ApplicationShortcutMenuTests.swift`
- Modify: `Tests/App/WorkspaceApplicationShortcutTests.swift`

**Interfaces:**
- Consumes: per-surface `TerminalFindController`.
- Produces: `FocusedValues.terminalFindController`, `EditMenuCommands`, `TerminalFindBar`, and active-scene shortcut routing.

- [ ] **Step 1: Add failing menu and scene-routing tests**

Verify:

- Find shortcuts are present only when a terminal presentation owns the focused Find controller;
- availability disables all Find commands for Herdr, Zellij, psmux, and unsupported tmux without falling through to libghostty;
- Command-F opens, a second Command-F increments field-selection revision, Command-G navigates next, Shift-Command-G navigates previous, and Shift-Command-F closes;
- nonterminal text fields retain AppKit's responder-chain Find behavior;
- rebinding catalog actions changes both the menu shortcut and terminal reservation.

- [ ] **Step 2: Add failing bar presentation and field-command tests**

Cover the pure presentation rules:

```swift
#expect(TerminalFindBar.statusText(for: .idle) == nil)
#expect(TerminalFindBar.statusText(for: .noMatch) == "No matches")
#expect(TerminalFindBar.statusText(
    for: .match(total: 5, selected: nil)
) == "5 matches")
#expect(TerminalFindBar.statusText(
    for: .match(total: 5, selected: 2)
) == "2 of 5")
#expect(TerminalFindBar.statusText(
    for: .match(total: nil, selected: nil)
) == nil)
```

Assert Return maps to `.next`, Shift-Return to `.previous`, Escape to `.close`, and ordinary typing to no command.

- [ ] **Step 3: Run the focused tests and verify routing is missing**

Run: `make swift-test SWIFT_TEST_FILTER='ApplicationShortcutMenuTests|WorkspaceApplicationShortcutTests|TerminalFindBarTests'`

Expected: FAIL because no focused controller, menu commands, or bar exists.

- [ ] **Step 4: Add the focused controller and Edit menu commands**

Define:

```swift
struct TerminalFindControllerKey: FocusedValueKey {
    typealias Value = TerminalFindController
}

extension FocusedValues {
    var terminalFindController: TerminalFindController? {
        get { self[TerminalFindControllerKey.self] }
        set { self[TerminalFindControllerKey.self] = newValue }
    }
}
```

Move the current pasteboard group from `GhosthubApp.editMenuCommands` into `EditMenuCommands`. After Select All, conditionally add Find commands only when the focused controller exists. Route through `WorkspaceSceneModel.performApplicationShortcut` so menu invocation and configured shortcuts share one path. Preserve the default responder chain when no terminal controller is focused.

- [ ] **Step 5: Route scene actions to the active controller**

Add `activeTerminalFindController` in `WorkspaceSceneModel`. Prefer the controller belonging to the active tmux handle; otherwise use the effectively focused ordinary surface. Add these switch cases:

```swift
case .find:
    guard let controller = activeTerminalFindController,
          controller.isAvailable else { return false }
    controller.open()
    return true
case .findNext:
    guard activeTerminalFindController?.canNavigate == true else { return false }
    activeTerminalFindController?.findNext()
    return true
case .findPrevious:
    guard activeTerminalFindController?.canNavigate == true else { return false }
    activeTerminalFindController?.findPrevious()
    return true
case .hideFindBar:
    guard activeTerminalFindController?.isOpen == true else { return false }
    activeTerminalFindController?.close()
    return true
```

Include available Find actions in command-palette availability only when the same controller conditions hold.

- [ ] **Step 6: Implement the bar and AppKit field**

`TerminalFindBar` uses `@ObservedObject var controller`, an `NSSearchField` representable, upward/downward chevrons, a close button, and the status rules tested above. The field observes `fieldSelectionRevision` and calls `selectText(nil)` after Command-F reopens an existing bar. Its `doCommandBy` delegate maps Return, Shift-Return, and Escape without inserting newline characters.

Use the active terminal's resolved foreground/background colors when available, falling back to `WorkspaceSurfaceColor` plus regular material. Give the field, result text, and buttons stable accessibility identifiers. The bar uses `.overlay(alignment: .topTrailing)` and never changes terminal layout or grid size.

- [ ] **Step 7: Host the bar and restore terminal focus on close**

In each native terminal view, publish `.focusedSceneValue(\.terminalFindController, surfaceView.terminalFindController)`. Render the bar only while the controller is open. On close, dispatch `surfaceView.requestKeyboardFocus()` after the field leaves the hierarchy. Herdr and Zellij publish unavailable controllers, so their bars never open. Apply the same host wrapper to ordinary libghostty-owned app surfaces, including the existing log viewer and any surface mounted through the existing console target.

- [ ] **Step 8: Run the focused app and UI tests**

Run: `make swift-test SWIFT_TEST_FILTER='ApplicationShortcutMenuTests|WorkspaceApplicationShortcutTests|ApplicationShortcutTests|TerminalFindBarTests|TerminalShortcutReservationTests'`

Expected: PASS with the four effective bindings reserved while terminal focus is active and normal text editing unchanged elsewhere.

- [ ] **Step 9: Commit the user interaction**

```bash
git add Sources/App/TerminalFindBar.swift Sources/App/WorkspaceWindow.swift Sources/App/MenuCommands.swift Sources/App/App.swift Sources/App/WorkspaceSceneModel.swift Sources/App/WorkspaceSceneModel+Selection.swift Sources/App/BorrowedTmuxSessionView.swift Sources/App/BorrowedHerdrSessionView.swift Sources/App/BorrowedZellijSessionView.swift Tests/App/TerminalFindBarTests.swift Tests/App/ApplicationShortcutMenuTests.swift Tests/App/WorkspaceApplicationShortcutTests.swift Tests/Terminal/TerminalShortcutReservationTests.swift
git commit -m "Add native terminal Find controls"
```

---

### Task 7: Complete Lifecycle, Failure, and Privacy Coverage

**Files:**
- Modify: `Tests/TerminalSupport/TerminalFindControllerTests.swift`
- Modify: `Tests/App/TmuxPaneFinderTests.swift`
- Modify: `Tests/App/NativeTmuxSessionCoordinatorTests.swift`
- Modify: `Tests/TerminalSmoke/TerminalSurfacePreviewTests.swift`
- Modify: `Tests/TerminalSmoke/LibghosttyFindSmokeTests.swift`

**Interfaces:**
- Verifies the complete design contract without adding new production API.

- [ ] **Step 1: Add the remaining lifecycle matrix before changing production code**

Cover one test per owned transition:

- clearing the query serially exits Find-owned tmux copy mode and a new query starts fresh at history bottom;
- closing during an in-flight command ignores its result, then cancels copy mode;
- surface teardown, disconnect, replacement, selection change, and preview parking close Find;
- reopened Find remembers and selects the last in-memory query but a replaced surface starts empty;
- a command that discovers copy mode already ended closes the bar without retargeting;
- state parsing ignores unrelated merged stdout/stderr;
- raw diagnostic and query text do not reach `terminalOperationErrorMessage` or `AppLogger`'s test sink;
- libghostty callbacks from a destroyed or different surface do not mutate the surviving controller.

- [ ] **Step 2: Run the focused matrix and observe any failures**

Run: `make swift-test SWIFT_TEST_FILTER='TerminalFindControllerTests|TmuxPaneFinderTests|NativeTmuxSessionCoordinatorTests|TerminalSurfacePreviewTests|LibghosttyFindSmokeTests'`

Expected: any failure identifies a missing lifecycle transition in owned code, not a configurable backend semantic.

- [ ] **Step 3: Make only the minimal lifecycle corrections required by the failing tests**

Use existing attachment IDs, controller session UUIDs, and query generations. Do not add retries, global locks, a selected-match model for tmux, or emacs/vi mode detection. Do not create a test-only production hook unless at least two tests need the same injection seam.

- [ ] **Step 4: Re-run the full focused matrix**

Run: `make swift-test SWIFT_TEST_FILTER='TerminalFindControllerTests|TmuxPaneFinderTests|NativeTmuxSessionCoordinatorTests|TerminalSurfacePreviewTests|LibghosttyFindSmokeTests'`

Expected: PASS with no owned surface or tmux server left running.

- [ ] **Step 5: Commit lifecycle completion**

```bash
git add Sources/TerminalSupport/TerminalFindController.swift Sources/Terminal/LibghosttyFind.swift Sources/Terminal/LibghosttyRuntime.swift Sources/Terminal/TerminalSurfaceView.swift Sources/App/TmuxPaneFinder.swift Sources/App/NativeTmuxSessionCoordinator.swift Tests/TerminalSupport/TerminalFindControllerTests.swift Tests/App/TmuxPaneFinderTests.swift Tests/App/NativeTmuxSessionCoordinatorTests.swift Tests/TerminalSmoke/TerminalSurfacePreviewTests.swift Tests/TerminalSmoke/LibghosttyFindSmokeTests.swift
git commit -m "Close Find with terminal lifecycle changes"
```

---

### Task 8: Documentation, Deterministic Demo, and Final Quality Gates

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/terminal-sessions.md`
- Modify: `website/docs/content/keyboard-shortcuts.md`
- Modify: `website/docs/content/sessions.md`
- Modify: `website/demo/assets/demohost.m`
- Modify: `website/demo/shoot.sh`
- Modify: `tools/tests/test_demo_scripts.py`

**Interfaces:**
- Documents the shipped behavior and prepares `guide-find.png` for the existing `website-assets` workflow.

- [ ] **Step 1: Update maintained architecture and terminal ownership docs**

Document that Find is a narrow backend-navigation control: tmux/libghostty retain pane text, highlighting, viewport, and match state. State the tmux 3.4 support floor, 3.5 count boundary, 3.6 command-rendering boundary, exact-client fence, pane-wide multi-client visibility, preview closure, unsupported backends, and no-history-text/no-query-log rules.

- [ ] **Step 2: Update the website Guide and shortcut table**

Add the four defaults and explain:

- Command-F opens Find for supported active terminals;
- Find Next walks toward older terminal history and Find Previous requests newer history;
- Ghostty.app/libghostty search is newest-to-oldest and non-wrapping;
- tmux owns wrapping and the first step after a direction change;
- tmux copy mode and viewport are pane-wide, so another attached client can see Find;
- Herdr, Zellij, psmux, and tmux older than 3.4 disable Find rather than searching only visible client output.

Reference `assets/guide-find.png` beside the workflow.

- [ ] **Step 3: Add a deterministic demo action for the Find bar**

Extend the injected demo controller with a `find` action that resolves the exact demo window, sends the configured Find command through the application menu, sets the `NSSearchField` value through its accessibility identifier, and submits it. The action must fail if the bar or expected `N matches` label is absent. Add script tests that assert the action is addressed only to the recorded demo process and that `shoot.sh` requests `guide-find.png`.

- [ ] **Step 4: Capture only after feature acceptance**

After the user accepts the completed visual behavior, run the documented isolated demo workflow:

```bash
cd website/demo
./stage.sh && ./run.sh
GHOSTHUB_DEMO_SKIP_SESSION_PREVIEWS=1 ./shoot.sh /tmp/ghosthub-website-assets
./teardown.sh
```

Inspect `guide-find.png` at original resolution and inspect its metadata. Do not use real host, project, account, session, or query data. Publishing the refreshed binary to the orphan `website-assets` branch and pushing it require the user's explicit push/PR authorization.

- [ ] **Step 5: Run documentation and demo checks**

Run:

```bash
make python-test
make docs-build
```

Expected: PASS, including the deterministic demo-script tests and the website's required asset reference.

- [ ] **Step 6: Run all terminal and repository quality gates**

Run in this order:

```bash
make format
make test-libghostty-bootstrap
make python-test
make swift-test
make test-essential-workflows
make build
git diff --check
```

Expected: every command exits successfully. Inspect the complete diff after the gates; confirm no pane text collection, query logging, unsupported fallback, compatibility alias, or unrelated refactor entered the branch.

- [ ] **Step 7: Commit documentation and demo support**

```bash
git add docs/architecture.md docs/terminal-sessions.md website/docs/content/keyboard-shortcuts.md website/docs/content/sessions.md website/demo/assets/demohost.m website/demo/shoot.sh tools/tests/test_demo_scripts.py
git commit -m "Document active-pane Find"
```

- [ ] **Step 8: Prepare the branch for an authorized push or pull request**

Before any push, remove the local planning artifacts, review the resulting deletion diff, run the public-data scrub against the complete unpushed history and any screenshot selected for publication, commit the removals without amending prior commits, and re-run the final quality gates required by the resulting diff. Do not push, open a pull request, publish `website-assets`, or start a RoboRev review unless the user explicitly requests that action.
