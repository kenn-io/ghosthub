# Keyboard Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local sibling session navigation, configurable Ghosthub application shortcuts, fixed native-tab shortcuts, and one resolved shortcut registry shared by Settings, menus, the command palette, scene dispatch, and terminal reservation.

**Architecture:** Put the AppKit-independent shortcut vocabulary, parser, validation, defaults, and resolved lookup in `GhosthubTerminalSupport`, the lowest existing module shared by Settings, UI, Terminal, and App. `SettingsStore` owns atomic loading and publication of the resolved registry from `config.toml`. `KeyboardNavigationModel` derives local sibling targets from `WorkspaceSidebarModel.sections`, and each focused `WorkspaceSceneModel` dispatches resolved actions while consuming an event only after a successful action. SwiftUI menus and command-palette labels project the same registry; AppKit adapters translate neutral bindings into `NSEvent` and menu equivalents. Native window tabs remain fixed system commands, with AppKit's Control-Tab aliases removed so Control-Tab is always sibling navigation or terminal input.

**Tech Stack:** Swift 6.2, Swift Testing, XCTest for existing AppKit/libghostty smoke harnesses, SwiftUI, AppKit, Combine, hand-written TOML parsing/editing, `kata`, Make.

## Global Constraints

- Follow `AGENTS.md`: use `kata` as the only tracker, commit every implementation task, push the completed task branch, never amend, and do not open a pull request unless explicitly requested.
- Apply test-driven development: add the failing observable-behavior test first, run it and confirm the expected failure, then implement the smallest production change and rerun the focused test.
- Use `WorkspaceSidebarModel.sections` as the only source for sibling visibility and ordering. Do not recreate sidebar filters or persisted-order logic in the keyboard layer.
- Only running Herdr sessions are keyboard-navigation targets. A shortcut must never restart a stopped session.
- Every configurable binding must include `cmd`, `ctrl`, or `opt`; `shift` alone is insufficient. Reject collisions with fixed system shortcuts and duplicate effective bindings atomically.
- A live invalid reload retains the currently published valid registry. A process starting with invalid shortcut configuration publishes compiled defaults and the error; there is no persisted last-valid cache.
- Do not disable shell integration, change tmux/Herdr key bindings, or synthesize multiplexer navigation keys.
- The spec and this plan are local planning artifacts. Remove both from the task branch before opening or updating a pull request.

---

### Task 1: Record deferred recency work and establish the neutral shortcut model

**Files:**

- Create: `Sources/TerminalSupport/ApplicationShortcut.swift`
- Create: `Tests/TerminalSupport/ApplicationShortcutTests.swift`

- [ ] **Step 1: Record recency navigation as deferred work**

  Search first, then create only if no equivalent issue exists:

  ```sh
  kata search "recent session navigation" --json
  kata create "Add recency-based session navigation" \
    --body "Add a separate recency-based navigation action without changing the stable local-sibling ordering introduced for GitHub issue #88." \
    --label area:ui --label priority:p3 --label enhancement \
    --idempotency-key "ghosthub-issue-88-recency-navigation" --json
  ```

  Run `kata edit` with `--related 4adh` and the issue reference returned by
  `kata create`. Keep the new issue separate from the implementation
  checklist; `kata` is the tracker.

- [ ] **Step 2: Write failing model, parser, validation, and default-catalog tests**

  Add parameterized Swift Testing coverage for:

  - all stable action IDs and the full defaults table;
  - normalized parsing for letters, digits, punctuation, arrows, Tab, Return, Escape, Delete, and F1–F12;
  - case-insensitive aliases (`command`/`cmd`, `control`/`ctrl`, `option`/`opt`);
  - canonical normalized strings and macOS display strings;
  - `"none"` as an explicit unbound override;
  - missing overrides selecting compiled defaults;
  - malformed keys/modifiers and repeated tokens;
  - bare and Shift-only input, including `shift+tab`, failing the non-Shift-modifier rule;
  - duplicate effective bindings and fixed-system reservations failing whole-set resolution;
  - unknown config keys being ignored by runtime resolution.

  Pin the string grammar in these tests. Split on `+`, accept modifiers before
  exactly one final key token, and normalize modifiers in
  `cmd+ctrl+opt+shift` order. Letters and digits normalize to lowercase;
  literal `,`, `.`, `/`, `;`, `'`, `[`, `]`, `\\`, `-`, `=`, and grave-accent
  tokens are accepted. Use named canonical tokens `plus`, `tab`,
  `return`, `escape`, `delete`, `left`, `right`, `up`, `down`, and `f1` through
  `f12`. Accept the long modifier aliases only as input. This makes the parser
  deterministic even for the plus key while preserving defaults such as
  `cmd+shift+,`. Render macOS display glyphs in Control, Option, Shift,
  Command, key order (for example `⌃⇧⇥` and `⇧⌘P`).

  Use these public shapes in the tests so downstream modules do not invent parallel representations:

  ```swift
  public enum ApplicationShortcutAction: String, CaseIterable, Sendable {
      case nextSibling = "next-sibling"
      case previousSibling = "previous-sibling"
      case selectSibling1 = "select-sibling-1"
      case selectSibling2 = "select-sibling-2"
      case selectSibling3 = "select-sibling-3"
      case selectSibling4 = "select-sibling-4"
      case selectSibling5 = "select-sibling-5"
      case selectSibling6 = "select-sibling-6"
      case selectSibling7 = "select-sibling-7"
      case selectSibling8 = "select-sibling-8"
      case selectSibling9 = "select-sibling-9"
      case commandPalette = "command-palette"
      case toggleSidebar = "toggle-sidebar"
      case newWorktree = "new-worktree"
      case importPullRequest = "import-pull-request"
      case newTmuxSession = "new-tmux-session"
      case newHerdrSession = "new-herdr-session"
      case splitRight = "split-right"
      case splitDown = "split-down"
      case reloadConfiguration = "reload-configuration"
      case openApplicationLog = "open-application-log"
  }

  public struct ApplicationShortcutModifiers: OptionSet, Hashable, Sendable {
      public static let command: Self
      public static let control: Self
      public static let option: Self
      public static let shift: Self
  }

  public enum ApplicationShortcutKey: Hashable, Sendable {
      case character(Character)
      case tab, `return`, escape, delete
      case leftArrow, rightArrow, upArrow, downArrow
      case function(Int)
  }

  public struct ApplicationKeyBinding: Hashable, Sendable {
      public var modifiers: ApplicationShortcutModifiers
      public var key: ApplicationShortcutKey
      public init(parsing value: String) throws
      public var configValue: String { get }
      public var displayText: String { get }
  }

  public enum ApplicationShortcutOverride: Equatable, Sendable {
      case binding(ApplicationKeyBinding)
      case unbound
  }

  public struct ResolvedApplicationShortcuts: Equatable, Sendable {
      public subscript(_ action: ApplicationShortcutAction) -> ApplicationKeyBinding? { get }
      public func action(for binding: ApplicationKeyBinding) -> ApplicationShortcutAction?
  }
  ```

  The catalog definition should also expose `title`, `settingsGroup`, `defaultBinding`, and `configKey` by action. Assert these exact defaults:

  ```text
  next-sibling=ctrl+tab
  previous-sibling=ctrl+shift+tab
  select-sibling-1 through select-sibling-9=unbound
  command-palette=cmd+shift+p
  toggle-sidebar=cmd+b
  new-worktree=cmd+shift+n
  import-pull-request=cmd+shift+i
  new-tmux-session=unbound
  new-herdr-session=unbound
  split-right=cmd+d
  split-down=cmd+shift+d
  reload-configuration=cmd+shift+,
  open-application-log=cmd+opt+l
  ```

- [ ] **Step 3: Run the focused tests and confirm they fail**

  ```sh
  swift test --filter ApplicationShortcutTests
  ```

  Expected: compilation fails because the neutral shortcut types do not exist.

- [ ] **Step 4: Implement parsing, formatting, catalog, and atomic resolution**

  Keep `ApplicationShortcut.swift` independent of `NSEvent` and SwiftUI. Define this exact initial fixed-reservation set as neutral bindings:

  - Previous/Next Tab: `cmd+shift+[` and `cmd+shift+]`
  - New Window: `cmd+n`
  - New Tab: `cmd+t`
  - Close presentation/window: `cmd+w`, `cmd+shift+w`
  - Settings: `cmd+,`
  - Quit: `cmd+q`
  - Edit commands: `cmd+x`, `cmd+c`, `cmd+v`, `cmd+a`

  `ApplicationShortcutCatalog.resolve(overrides:)` must build a complete candidate set, validate every candidate, reject the entire candidate on the first deterministic error, then return an immutable bidirectional lookup. Error values must identify the action and conflicting/reserved owner so Settings can render precise messages.

- [ ] **Step 5: Rerun focused tests**

  ```sh
  swift test --filter ApplicationShortcutTests
  ```

  Expected: all tests pass.

- [ ] **Step 6: Format and commit**

  ```sh
  make format
  git diff --check
  git status --short
  ```

  Use the required commit skill, stage only Task 1 files, and commit with a message such as `Add neutral application shortcut registry`.

---

### Task 2: Parse, edit, and atomically publish shortcut configuration

**Files:**

- Create: `Sources/Settings/ShortcutPreferences.swift`
- Create: `Tests/Settings/ShortcutPreferencesTests.swift`
- Modify: `Sources/Settings/AppConfigEditor.swift`
- Modify: `Sources/Settings/SettingsStore.swift`
- Modify: `Sources/Settings/SettingsViewDraft.swift`
- Modify: `Tests/Settings/AppConfigEditorTests.swift`
- Modify: `Tests/Settings/SettingsStoreTests.swift`
- Modify: `Tests/Settings/SettingsViewDraftTests.swift`
- Modify: `Sources/Workspace/TOMLConfigParser.swift`
- Modify: `Tests/Workspace/TOMLConfigParserTests.swift`

- [ ] **Step 1: Write failing TOML and store-lifecycle tests**

  Cover these contracts:

  - `[keyboard.shortcuts]` reads known string keys and `"none"` while preserving unknown keys;
  - invalid known scalar types or malformed bindings return a typed load error rather than silently defaulting that action;
  - a fresh `SettingsStore` with an invalid table publishes `ApplicationShortcutCatalog.defaults` and exposes the exact error;
  - a valid live reload replaces the full registry once;
  - an invalid live reload retains the prior `shortcutPreferences.resolved` value and publishes the error;
  - Settings persistence validates the full draft before touching disk or runtime state;
  - successful persistence performs one atomic file write and one resolved-registry publication;
  - replacing one scalar keeps LF/CRLF style, unrelated sections, unknown keys, surrounding comments, and inline comments;
  - Clear writes `"none"`; Restore Default removes only the known assignment and preserves any inline comment as a standalone comment;
  - a draft is initialized from overrides, not merely effective defaults, so Restore Default remains distinguishable from an explicit default-valued override.

  Introduce these settings-facing values:

  ```swift
  public struct ShortcutPreferences: Equatable, Sendable {
      public var overrides: [ApplicationShortcutAction: ApplicationShortcutOverride]
      public var resolved: ResolvedApplicationShortcuts
  }

  public struct ShortcutConfigurationIssue: Error, Equatable, Sendable {
      public var action: ApplicationShortcutAction?
      public var message: String
  }
  ```

  Extend `SettingsPersistResult` with `didPersistShortcuts`, and `SettingsViewDraft` with `shortcutOverrides` plus validation state derived from the catalog.

- [ ] **Step 2: Run focused tests and confirm the failures**

  ```sh
  swift test --filter AppConfigEditorTests
  swift test --filter ShortcutPreferencesTests
  swift test --filter SettingsStoreTests
  swift test --filter SettingsViewDraftTests
  swift test --filter TOMLConfigParserTests
  ```

  Expected: new parser/editor/store APIs are missing.

- [ ] **Step 3: Add scalar TOML discovery and surgical editing**

  Extend `TOMLConfigParser` with a section assignment reader that returns every scalar assignment in a named table without dropping the raw key. Do not change existing array behavior. Add an editor operation with optional value:

  ```swift
  static func replacingString(
      sectionName: String,
      key: String,
      value: String?,
      in contents: String
  ) -> String
  ```

  A non-nil value renders with `TOMLConfigParser.renderTOMLString`. A nil value removes the override. Build `replacingStrings(sectionName:values:in:)` so Settings applies all shortcut changes in memory and writes once, rather than rewriting the file once per action.

- [ ] **Step 4: Implement startup versus live-reload semantics in `SettingsStore`**

  During initialization:

  ```swift
  switch ShortcutPreferences.load(from: appConfigFile) {
  case let .success(preferences):
      shortcutPreferences = preferences
      shortcutConfigurationIssue = nil
  case let .failure(issue):
      shortcutPreferences = .compiledDefaults
      shortcutConfigurationIssue = issue
  }
  ```

  During `reload()`, assign `shortcutPreferences` only on success. On failure, leave its existing resolved set unchanged and update `shortcutConfigurationIssue`. Do not clear the shortcut error via the general `lastErrorMessage = nil` path. Add a batch `setShortcutOverrides(_:) -> Bool` that validates first, edits from the current file contents, writes atomically, then publishes the candidate preferences.

- [ ] **Step 5: Extend the Settings draft lifecycle**

  Stage edits in `SettingsViewDraft.shortcutOverrides`. `persist(to:)` calls `setShortcutOverrides` once, includes its result in `SettingsPersistResult`, and does not publish partial changes. Update the Done button in `Sources/UI/SettingsView.swift` so it dismisses only when both tmux-pattern and shortcut persistence succeed. Keep `onDisappear` as a best-effort persistence path for system-driven dismissal, and retain the store's error for the next presentation instead of falsely publishing the draft.

- [ ] **Step 6: Rerun focused tests**

  ```sh
  swift test --filter AppConfigEditorTests
  swift test --filter ShortcutPreferencesTests
  swift test --filter SettingsStoreTests
  swift test --filter SettingsViewDraftTests
  swift test --filter TOMLConfigParserTests
  ```

  Expected: all pass.

- [ ] **Step 7: Format and commit**

  ```sh
  make format
  git diff --check
  ```

  Commit only Task 2 files with `Load configurable shortcuts atomically`.

---

### Task 3: Resolve local siblings from sidebar structure

**Files:**

- Modify: `Sources/UI/KeyboardNavigationModel.swift`
- Modify: `Tests/UI/KeyboardNavigationModelTests.swift`

- [ ] **Step 1: Replace global-worktree tests with failing local-group tests**

  Test the public target-based API:

  ```swift
  public struct KeyboardNavigationContext: Sendable {
      public var snapshot: WorkspaceSnapshot
      public var visibility: WorktreeVisibility
      public var tmuxSessionVisibility: TmuxSessionVisibility
      public var worktreeOrderRawValue: String
      public var tmuxSessionOrderRawValue: String
      public var herdrSessionOrderRawValue: String
  }

  public static func siblingTargets(
      for currentTarget: WorkspaceNavigationTarget,
      in context: KeyboardNavigationContext
  ) -> [WorkspaceNavigationTarget]

  public static func steppedTarget(
      from currentTarget: WorkspaceNavigationTarget,
      step: Int,
      in context: KeyboardNavigationContext
  ) -> WorkspaceNavigationTarget?

  public static func targetForShortcutIndex(
      _ index: Int,
      from currentTarget: WorkspaceNavigationTarget,
      in context: KeyboardNavigationContext
  ) -> WorkspaceNavigationTarget?
  ```

  Cover:

  - worktrees are siblings only inside the same repository project, never across repositories or hosts;
  - directory workspaces are siblings among directory-workspace rows in the same host's Projects group;
  - standalone tmux rows are siblings on one host after `TmuxSessionVisibility` filtering;
  - only running Herdr rows are siblings on one host; stopped rows are excluded even though `sections` returns them;
  - persisted order for all three reorderable row kinds, forward/backward wrapping, and numbered selection;
  - disclosure state and sidebar visibility are absent from the API and cannot alter results;
  - hidden, stale, missing, host, and project targets return no action;
  - zero or one eligible target returns nil, including index 1, so the shortcut passes through rather than reselecting the current row;
  - an out-of-range numbered selection returns nil.

- [ ] **Step 2: Run and confirm failure**

  ```sh
  swift test --filter KeyboardNavigationModelTests
  ```

  Expected: target-based sibling APIs are missing.

- [ ] **Step 3: Implement one shared group resolver**

  Call `WorkspaceSidebarModel.sections` once with every context field. Find the current row and return exactly one of:

  - matching `WorkspaceSidebarProject.worktreeRows`;
  - the host section's `directoryWorkspaceRows`;
  - the host section's `tmuxSessionRows`;
  - the host section's `herdrSessionRows.filter { $0.herdrSessionState == .running }`.

  Both step and index functions call this resolver. Require `targets.count >= 2` before returning any navigation result. Keep the three existing global-worktree functions temporarily so the branch continues compiling between tasks; mark their removal as part of Task 4 after the App callers migrate.

- [ ] **Step 4: Rerun, format, and commit**

  ```sh
  swift test --filter KeyboardNavigationModelTests
  make format
  git diff --check
  ```

  Expected: tests pass. Commit with `Resolve keyboard navigation within sibling groups`.

---

### Task 4: Translate AppKit events and dispatch only in the focused scene

**Files:**

- Create: `Sources/TerminalSupport/ApplicationShortcut+AppKit.swift`
- Modify: `Sources/App/App.swift`
- Modify: `Sources/App/ShortcutMonitor.swift`
- Modify: `Sources/App/WorkspaceSceneModel+Selection.swift`
- Modify: `Sources/App/WorkspaceSceneModel.swift`
- Modify: `Sources/UI/KeyboardNavigationModel.swift`
- Modify: `Sources/UI/WorkspaceMenuNotifications.swift`
- Modify: `Sources/UI/RootView.swift`
- Modify: `Tests/App/ShortcutMonitorTests.swift`
- Create: `Tests/App/WorkspaceApplicationShortcutTests.swift`
- Modify: `Tests/TerminalSmoke/TerminalSurfaceViewInputTests.swift`

- [ ] **Step 1: Write failing AppKit translation and monitor-consumption tests**

  Replace `InterceptedShortcutAction` expectations with neutral bindings and resolved actions. Cover:

  - key codes for Tab, arrows, Return, Escape, Delete, and function keys translate correctly even when `charactersIgnoringModifiers` is nil;
  - device-dependent modifier flags are ignored;
  - the monitor reads the provider on every event, so a live registry update takes effect without reinstalling it;
  - a matched action is consumed only when `perform(action)` returns true;
  - unmatched, unbound, unavailable, and unfocused actions return the identical event;
  - repeats do not retrigger presentation actions, while held navigation may repeat deliberately; encode the selected policy in `ApplicationShortcutCatalog` rather than hard-code it in the monitor.

  Refactor to this narrow monitor surface:

  ```swift
  init(
      shortcuts: @escaping () -> ResolvedApplicationShortcuts,
      perform: @escaping (ApplicationShortcutAction) -> Bool
  )
  ```

- [ ] **Step 2: Write failing scene-dispatch tests**

  Cover availability and observable effects for:

  - next/previous/indexed sibling using the active presentation as current target before falling back to `selection.navigationTarget`;
  - active standalone tmux and Herdr presentations taking precedence over the host-level normalized selection;
  - worktree and directory targets selecting through `selectFromUser` so canonical attachment behavior remains intact;
  - standalone tmux opening via `openBorrowedTmuxSession`;
  - running Herdr opening via `openBorrowedHerdrSession`, with the shortcut consumed once the valid attach request is scheduled;
  - stopped Herdr never being scheduled;
  - command palette, sidebar, creation sheets, reload, log, and split actions only reporting success when their scene-specific availability check passes;
  - only `isFocusedWindow == true` dispatching.

  Add a scene-scoped notification for the four modal actions RootView owns:

  ```swift
  public static let ghosthubApplicationShortcutRequest: Notification.Name
  // notification.object is the scene's existing sidebarToggleTarget
  // notification.userInfo carries ApplicationShortcutAction
  ```

  `RootView` must observe only its own object and map `newWorktree`, `importPullRequest`, `newTmuxSession`, and `newHerdrSession` to existing sheet state. Do not broadcast these requests to every tab/window.

- [ ] **Step 3: Write the ordering/pass-through smoke test before implementation**

  In `TerminalSurfaceViewInputTests`, assemble the real `ShortcutMonitor.processForTesting(_:)` and `TerminalSurfaceView.processLocalEventForTesting(_:)` path:

  - when the scene callback succeeds for `ctrl+tab`, the monitor returns nil and the terminal never receives the event;
  - when the callback returns false, the same event reaches the terminal local handler;
  - when `next-sibling` is unbound, the same event reaches the terminal;
  - repeat the pass-through case while a synthetic native tab group/menu exists after Task 7 to prove no Window-menu Control-Tab fallback remains.

  This test protects the local-monitor installation-order contract called out in the design review.

- [ ] **Step 4: Run focused tests and confirm failure**

  ```sh
  swift test --filter ShortcutMonitorTests
  swift test --filter WorkspaceApplicationShortcutTests
  swift test --filter TerminalSurfaceViewInputTests
  ```

- [ ] **Step 5: Implement neutral AppKit conversion and scene dispatch**

  Add `ApplicationKeyBinding.init?(event:)` in the TerminalSupport AppKit adapter so both the App and Terminal targets can use one key-code translation. Keep SwiftUI `KeyboardShortcut` conversion in a private App-target extension because TerminalSupport must not depend on SwiftUI. In `WorkspaceSceneModel`, derive current target in this order:

  ```swift
  if let activeHerdr = activeBorrowedHerdrSelection {
      return .herdrSession(hostID: activeHerdr.hostID, name: activeHerdr.name)
  }
  if let activeTmux = activeBorrowedTmuxSelection {
      if let id = activeTmux.worktreeID { return .worktree(id) }
      if let id = activeTmux.directoryWorkspaceID { return .directoryWorkspace(id) }
      return .tmuxSession(hostID: activeTmux.hostID, name: activeTmux.name)
  }
  return selection.navigationTarget
  ```

  Read all order values from `WorkspaceSidebarOrderStorage`. Add `tmuxSessionRawValue(in:)` and `herdrSessionRawValue(in:)` beside the existing `worktreeRawValue(in:)`. For a selected target, use the existing App-layer open/select methods rather than mutating `WorkspaceSelection` directly for standalone sessions.

  After all App callers use the target-based resolver, delete
  `orderedWorktrees`, `steppedSelection`, and `selectionForShortcutIndex` and
  remove their obsolete global-navigation tests. There must be no legacy
  fallback to cross-project worktree navigation.

  Add an App-layer invocation source and a single dispatcher:

  ```swift
  enum ApplicationShortcutInvocation {
      case keyEvent
      case menu
  }

  func performApplicationShortcut(
      _ action: ApplicationShortcutAction,
      invocation: ApplicationShortcutInvocation
  ) -> Bool
  ```

  The monitor always passes `.keyEvent`. A menu button determines `.keyEvent`
  versus `.menu` from `NSApplication.shared.currentEvent`, preserving the
  existing rule that a split key requires effective terminal focus while an
  explicit enabled menu click may split the active capable pane without moving
  focus first. For split key events, call
  `splitActivePane(requestedSplit, requiresKeyboardFocus: true)` only after a new
  `canSplitActivePaneWithKeyboardFocus` check; do not report success merely
  because a handler exists. All other actions have the same availability for
  both invocation sources.

- [ ] **Step 6: Reload Settings shortcuts with terminal configuration**

  Update `WorkspaceSceneModel.reloadTerminalConfig()` to call a dedicated `SettingsStore.reloadShortcutConfiguration()` before `terminalRuntime.reloadConfig`. Log `shortcutConfigurationIssue` through `AppLogger` at startup and on failed manual reload, while Settings remains responsible only for exposing the typed error.

- [ ] **Step 7: Rerun, format, and commit**

  ```sh
  swift test --filter ShortcutMonitorTests
  swift test --filter WorkspaceApplicationShortcutTests
  swift test --filter TerminalSurfaceViewInputTests
  make format
  git diff --check
  ```

  Commit with `Dispatch configurable shortcuts in the focused scene`.

---

### Task 5: Build the editable Keyboard Settings recorder

**Files:**

- Create: `Sources/UI/ShortcutRecorder.swift`
- Modify: `Sources/UI/ApplicationShortcutsView.swift`
- Modify: `Sources/UI/SettingsView.swift`
- Create: `Tests/UI/ShortcutRecorderTests.swift`
- Modify: `Tests/UI/ApplicationShortcutsViewTests.swift`
- Modify: `Tests/UI/SettingsViewTests.swift`

- [ ] **Step 1: Write failing recorder-state tests**

  Keep event capture AppKit-specific but make recorder state a testable value/model. Cover:

  - clicking starts recording and displays the next candidate;
  - Escape cancels and preserves the prior override;
  - Clear sets `.unbound` and displays `None`;
  - Restore Default removes the override and displays the compiled default or `None` for unbound defaults;
  - duplicate, fixed-reserved, malformed, bare, and Shift-only candidates remain visibly rejected with action-specific inline text;
  - validation considers the complete draft, not only the persisted registry;
  - a valid replacement clears the previous error;
  - accessibility values expose action title, current binding, recording state, Clear, Restore Default, and error text.

- [ ] **Step 2: Write failing Keyboard pane structure tests**

  Replace the old static shortcut list expectations with catalog-backed sections:

  - Navigation: previous/next and select sibling 1–9;
  - Application: palette, sidebar, creation/import, reload, log;
  - Multiplexer: split right/down;
  - System Shortcuts: fixed, read-only macOS actions.

  Assert the native-tab rows display only `⇧⌘[` and `⇧⌘]`, with no Control-Tab aliases. Assert Settings renders the startup/live config issue without rewriting the file.

- [ ] **Step 3: Run focused tests and confirm failure**

  ```sh
  swift test --filter ShortcutRecorderTests
  swift test --filter ApplicationShortcutsViewTests
  swift test --filter SettingsViewTests
  ```

- [ ] **Step 4: Implement the recorder and catalog-driven pane**

  `ApplicationShortcutsView` receives bindings to `SettingsViewDraft.shortcutOverrides` and the store's current config issue. Render catalog definitions by `settingsGroup`, with system rows from a fixed reference catalog. The recorder captures one key-down event, converts it to `ApplicationKeyBinding`, validates a candidate full override map, and commits only valid candidates to the draft.

  Prevent the recorder event from reaching the terminal or another Settings control while recording. Escape cancels recording rather than binding Escape by itself; users may still bind a modified Escape combination.

- [ ] **Step 5: Rerun, format, and commit**

  ```sh
  swift test --filter ShortcutRecorderTests
  swift test --filter ApplicationShortcutsViewTests
  swift test --filter SettingsViewTests
  swift test --filter SettingsViewDraftTests
  make format
  git diff --check
  ```

  Commit with `Make application shortcuts editable in Settings`.

---

### Task 6: Drive menus and command-palette labels from the registry

**Files:**

- Modify: `Sources/App/App.swift`
- Modify: `Sources/UI/CommandPaletteModel.swift`
- Modify: `Sources/UI/CommandPaletteView.swift`
- Modify: `Sources/UI/RootView.swift`
- Modify: `Tests/UI/CommandPaletteModelTests.swift`
- Modify: `Tests/App/PaneSplitCommandTests.swift`
- Create: `Tests/App/ApplicationShortcutMenuTests.swift`

- [ ] **Step 1: Write failing palette projection tests**

  Remove `WorkspaceCommandShortcut` and test `WorkspaceCommandItem.shortcutAction: ApplicationShortcutAction?` plus a derived label supplied from `ResolvedApplicationShortcuts`. Cover:

  - command palette, sidebar, reload, new worktree, import PR, creation, split, and log labels derive from the registry;
  - changing or unbinding a registry entry changes/removes its label without altering action availability;
  - Import Pull Request displays the real `cmd+shift+i` default only for the selected eligible project and dispatches `.importPullRequest(project.id)`;
  - unbound new tmux/Herdr actions remain discoverable without labels;
  - old previous/next worktree items and Cmd-1–9 labels are removed;
  - no command has a non-nil displayed label without both a registry action and an executable `WorkspaceCommandAction`;
  - the unused `commandShiftDelete` representation is gone.

- [ ] **Step 2: Write failing menu binding tests**

  Extract a small testable projection such as:

  ```swift
  struct ApplicationShortcutMenuItem: Equatable {
      let action: ApplicationShortcutAction
      let title: String
      let binding: ApplicationKeyBinding?
  }
  ```

  Assert the Session menu includes Next/Previous Sibling and optional numbered actions, and all configurable File/View/application menu entries use the current registry. Fixed Settings, Quit, Edit, New Window/Tab, Close, and native-tab items stay outside the registry.

- [ ] **Step 3: Run focused tests and confirm failure**

  ```sh
  swift test --filter CommandPaletteModelTests
  swift test --filter ApplicationShortcutMenuTests
  ```

- [ ] **Step 4: Implement dynamic menu and palette projections**

  Observe `SettingsStore.shared.shortcutPreferences` from `GhosthubApp`. Convert a neutral binding to SwiftUI `KeyboardShortcut` only at the App boundary. Route menu activation through `focusedSceneModel?.performApplicationShortcut(action, invocation:)`; determine the invocation from the current AppKit event as described in Task 4 so the existing split-focus distinction remains deliberate.

  Remove `PaneSplitCommand` and its hard-coded matching assertions. Split menu key equivalents come from `.splitRight` and `.splitDown`, while `performApplicationShortcut` enforces connected-surface keyboard focus for key events and permits an explicit menu click to request a split without manufacturing a key event. Replace `PaneSplitCommandTests` with equivalent assertions in `ApplicationShortcutMenuTests` and scene-dispatch tests.

  For the palette, pass the resolved registry into `CommandPaletteModel.commands` and render `binding.displayText`. Build configurable command titles from the catalog definition title, adding only contextual suffixes such as `in Ghosthub` or `on Local Mac` in the palette model. Preserve contextual `WorkspaceCommandAction` payloads for project/host-specific commands; `shortcutAction` identifies the registry definition and binding. Delete the hard-coded `WorkspaceCommandShortcut` enum.

- [ ] **Step 5: Rerun, format, and commit**

  ```sh
  swift test --filter CommandPaletteModelTests
  swift test --filter ApplicationShortcutMenuTests
  make format
  git diff --check
  ```

  Commit with `Project resolved shortcuts into menus and palette`.

---

### Task 7: Make bracket keys the only native-tab equivalents

**Files:**

- Create: `Sources/App/NativeTabCommands.swift`
- Modify: `Sources/App/App.swift`
- Modify: `Sources/App/ApplicationDelegate.swift`
- Modify: `Sources/App/WorkspaceWindow.swift`
- Create: `Tests/App/NativeTabCommandsTests.swift`
- Modify: `Tests/App/WorkspaceTabRequestTests.swift`
- Modify: `Tests/TerminalSmoke/TerminalSurfaceViewInputTests.swift`

- [ ] **Step 1: Write failing native-menu ownership tests**

  Build a synthetic recursive `NSMenu` containing items whose actions are `#selector(NSWindow.selectNextTab(_:))` and `#selector(NSWindow.selectPreviousTab(_:))`. Assert the suppression helper:

  - clears Control-Tab and Control-Shift-Tab equivalents from those selectors;
  - leaves unrelated Control-Tab items untouched;
  - leaves clickable tab actions intact;
  - is idempotent;
  - does not remove the custom bracket equivalents.

  Extend tab request tests to assert previous/next actions target the active native tab group and wrap using AppKit behavior.

- [ ] **Step 2: Run focused tests and confirm failure**

  ```sh
  swift test --filter NativeTabCommandsTests
  swift test --filter WorkspaceTabRequestTests
  ```

- [ ] **Step 3: Implement fixed Window menu commands**

  Add Previous Tab and Next Tab under the Window command placement with fixed `cmd+shift+[` and `cmd+shift+]` equivalents. Dispatch with AppKit's native `selectPreviousTab(_:)` / `selectNextTab(_:)` responder-chain actions; do not model tabs in Swift.

  Add a recursive `NativeTabCommands.removeControlTabAliases(from:)`. Invoke it after SwiftUI constructs the main menu, when the application becomes active, and after `addTabbedWindow` so AppKit cannot reintroduce aliases when a tab group changes. Keep `NSWindow.allowsAutomaticWindowTabbing = false` because it independently preserves Cmd-N as a new window.

- [ ] **Step 4: Complete the real pass-through smoke case**

  Extend the Task 4 test to install/sanitize a synthetic native-tab menu before sending unavailable `ctrl+tab`. Assert the monitor returns the event, the menu has no matching key equivalent, and the terminal handler receives it. Add the symmetric `ctrl+shift+tab` case.

- [ ] **Step 5: Rerun, format, and commit**

  ```sh
  swift test --filter NativeTabCommandsTests
  swift test --filter WorkspaceTabRequestTests
  swift test --filter TerminalSurfaceViewInputTests
  make format
  git diff --check
  ```

  Commit with `Reserve bracket shortcuts for native tabs`.

---

### Task 8: Use the resolved registry for terminal application-shortcut reservation

**Files:**

- Modify: `Sources/TerminalSupport/TerminalApplicationShortcut.swift`
- Modify: `Sources/TerminalSupport/TerminalPaneSplitShortcut.swift`
- Modify: `Sources/Terminal/TerminalSurfaceView.swift`
- Modify: `Sources/TerminalUnavailable/TerminalSurfaceStubs.swift`
- Modify: `Sources/Terminal/TerminalSurfaceCoordinator.swift`
- Modify: `Sources/App/WorkspaceSceneModel.swift`
- Modify: `Tests/Terminal/TerminalShortcutReservationTests.swift`
- Modify: `Tests/TerminalSupport/TerminalPaneSplitShortcutTests.swift`
- Modify: `Tests/TerminalSmoke/TerminalSurfaceViewInputTests.swift`

- [ ] **Step 1: Write failing dynamic-reservation tests**

  Cover:

  - every effective Command-modified configurable binding is reserved from libghostty;
  - a reconfigured binding replaces its prior reservation immediately;
  - an unbound action reserves nothing;
  - Control- and Option-only configurable bindings are not terminal-reserved because scene monitoring decides them before terminal handling;
  - fixed Cmd-Q, Cmd-comma, Cmd-N, Cmd-T, Cmd-W, Cmd-Shift-W, and bracket native-tab combinations retain their current responder-chain behavior;
  - Cmd-W still respects `hasPaneCloseHandler` exactly as today;
  - pane-split recognition maps the event through the resolved `.splitRight` / `.splitDown` actions, so reconfiguration removes the old Cmd-D behavior and installs the new Command-modified binding;
  - real and unavailable terminal targets expose identical APIs and results.

- [ ] **Step 2: Run focused tests and confirm failure**

  ```sh
  swift test --filter TerminalShortcutReservationTests
  swift test --filter TerminalSurfaceViewInputTests
  ```

- [ ] **Step 3: Replace the configurable hard-coded list**

  Change reservation to accept the current registry:

  ```swift
  public static func isReserved(
      binding: ApplicationKeyBinding,
      shortcuts: ResolvedApplicationShortcuts,
      hasPaneCloseHandler: Bool
  ) -> Bool
  ```

  Keep a small explicit fixed-system set, then reserve a configurable match only when `binding.modifiers.contains(.command)` and `shortcuts.action(for: binding) != nil`.

  Give `TerminalSurfaceView` and its stub a provider property with the same signature:

  ```swift
  public var applicationShortcutsProvider:
      (() -> ResolvedApplicationShortcuts)?
  ```

  The terminal reads the provider per event so live reloads are immediate. In `WorkspaceSceneModel` initialization, use `TerminalSurfaceCoordinator.onSurfaceCreated` to install a weak/provider closure returning `SettingsStore.shared.shortcutPreferences.resolved` on every surface, including surfaces created after reload. Preserve any existing `onSurfaceCreated` behavior rather than overwriting it silently; compose callbacks if necessary.

  Replace `TerminalPaneSplitShortcut.matching(flags:charactersIgnoringModifiers:)` with an AppKit-independent mapping from `ApplicationShortcutAction.splitRight` / `.splitDown`. `TerminalSurfaceView.paneSplitShortcut(for:)` first converts the event to `ApplicationKeyBinding`, looks it up in the provider's resolved registry, and then maps the action. Fall back to compiled defaults only when no provider was installed, so isolated terminal tests and non-workspace surfaces retain default behavior without a second hard-coded chord list.

- [ ] **Step 4: Rerun, format, and commit**

  ```sh
  swift test --filter TerminalShortcutReservationTests
  swift test --filter TerminalSurfaceViewInputTests
  make format
  git diff --check
  ```

  Commit with `Share shortcut reservations with terminal surfaces`.

---

### Task 9: Document the accepted keyboard workflow

**Files:**

- Modify: `website/docs/content/keyboard-shortcuts.md`
- Modify: `website/docs/content/windows-navigation.md`
- Modify: `README.md`
- Modify: `docs/architecture.md` only if implementation changes a stated architectural boundary
- Modify: deterministic website demo/capture fixtures only if the accepted Settings UI materially changes a published screenshot

- [ ] **Step 1: Update user-facing guidance**

  Document:

  - native Previous/Next Tab as fixed Cmd-Shift-[ and Cmd-Shift-];
  - next/previous local sibling as configurable Ctrl-Tab/Ctrl-Shift-Tab defaults;
  - the four sibling groups, running-only Herdr rule, persisted sidebar order, wrap, and pass-through with fewer than two siblings;
  - removal of Cmd-1–9 and Cmd-Option-Up/Down defaults;
  - Settings recorder, Clear, Restore Default, and conflict errors;
  - `[keyboard.shortcuts]`, normalized values, `"none"`, modifier requirements, duplicates/reservations, and atomic invalid-file behavior;
  - Reload Configuration applying both app and terminal configuration;
  - Ghosthub does not configure tmux/Herdr bindings and ordinary unavailable shortcuts reach the terminal.

  Update the README's compact shortcut table to match defaults without duplicating the full configuration reference.

- [ ] **Step 2: Build the website documentation**

  Run the repository-pinned website checks (there is no non-deploying root
  Make target for the public site):

  ```sh
  cd website
  pnpm check
  pnpm lint
  pnpm test
  pnpm build
  ```

  Expected: documentation links and markup build without errors.

- [ ] **Step 3: Handle screenshots only at acceptance**

  Compare the accepted Keyboard Settings view against screenshots referenced by the guide. If materially changed, use deterministic synthetic demo data, run the documented capture workflow, and publish refreshed binaries to `website-assets` before any PR. If no current guide screenshot shows Keyboard Settings, record that no capture is required; do not add an ornamental screenshot.

- [ ] **Step 4: Commit documentation**

  ```sh
  git diff --check
  ```

  Commit with `Document configurable keyboard navigation`.

---

### Task 10: Run full gates, audit behavior, and prepare the branch handoff

**Files:**

- Modify: implementation/tests/docs only for defects revealed by verification
- Remove before PR only: `docs/superpowers/specs/2026-08-09-keyboard-navigation-design.md`
- Remove before PR only: `docs/superpowers/plans/2026-08-09-keyboard-navigation.md`

- [ ] **Step 1: Run formatting and all mandated regression gates**

  ```sh
  make format
  make format-check
  make test-libghostty-bootstrap
  make python-test
  swift test
  make test-essential-workflows
  make build
  ```

  Expected: every command exits zero. If any fails, invoke `superpowers:systematic-debugging`, add/strengthen the narrowest regression test, fix the cause, and rerun the failed command plus any dependent gates.

- [ ] **Step 2: Perform focused manual acceptance**

  Using synthetic/local disposable sessions rather than private production data, verify:

  1. Cmd-Shift-[ / ] switches native tabs; Ctrl-Tab never switches tabs.
  2. Ctrl-Tab and Ctrl-Shift-Tab wrap inside each eligible sibling group and never cross host/project boundaries.
  3. A stopped Herdr row is skipped and never restarted.
  4. With zero/one sibling, Ctrl-Tab reaches a terminal TUI; repeat with multiple native tabs.
  5. Cmd-1–9 and Cmd-Option-Up/Down are not captured by default.
  6. Recorder edits are staged until Settings closes; Clear, Restore Default, conflict, and accessibility behavior work.
  7. Editing `config.toml` and Reload Configuration updates menus, palette, monitor, and terminal reservation together.
  8. Invalid live config retains the prior bindings; relaunch with the invalid file uses all compiled defaults and reports the error.
  9. Import Pull Request's Cmd-Shift-I performs the advertised action; unbound items show no phantom label.

- [ ] **Step 3: Audit for duplicate shortcut sources and private data**

  ```sh
  rg -n "commandOptionUp|commandOptionDown|commandDigit|commandShiftDelete|Select worktree 1|Previous worktree|Next worktree" Sources Tests README.md website/docs
  rg -n "keyboardShortcut" Sources/App Sources/UI
  git diff --check
  git status --short
  ```

  Expected: removed legacy symbols/text have no hits; remaining `keyboardShortcut` calls are fixed system actions or registry-derived adapters. Invoke `kenn:scrub-private-data` before any public push/PR and remediate every relevant finding.

- [ ] **Step 4: Update `kata` with evidence**

  ```sh
  kata comment 4adh --body "Implemented local sibling keyboard navigation and configurable shortcuts. Full gates passed: make format-check, make test-libghostty-bootstrap, make python-test, swift test, make test-essential-workflows, and make build." --json
  ```

  Do not close `4adh` until all implementation, documentation, and required asset publication are complete.

- [ ] **Step 5: Commit any verification fixes and verify a clean branch**

  Use the commit skill for any fixes; never amend. Then:

  ```sh
  git status --short --branch
  git log --oneline --decorate -8
  ```

  Expected: clean task worktree on a non-default branch.

- [ ] **Step 6: Remove planning artifacts only when a PR is explicitly requested**

  Before opening/updating a PR, remove the spec and this plan, commit that removal, rerun `git diff --check`, use `kenn:scrub-private-data`, and push. Do not open a PR during ordinary implementation handoff; the user must explicitly request it.

- [ ] **Step 7: Push completed task commits**

  ```sh
  git push origin HEAD
  ```

  Do not poll GitHub Actions unless explicitly asked.
