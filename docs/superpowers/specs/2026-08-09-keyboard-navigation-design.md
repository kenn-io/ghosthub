# Keyboard Navigation and Configurable Shortcuts

## Context

GitHub issue #88 asks for keyboard-driven session cycling. Ghosthub already
has native macOS window tabs, a read-only Keyboard Settings page, and
hard-coded shortcuts that cycle or select worktrees globally. Those pieces do
not share one shortcut definition, do not include standalone tmux or Herdr
sessions, and currently capture Command-1 through Command-9 even when the user
needs those combinations for macOS Spaces.

This design gives native tabs and sidebar sessions distinct navigation
semantics, makes Ghosthub-specific shortcuts configurable, and keeps ordinary
terminal input under tmux or Herdr control unless Ghosthub can perform the
configured action.

## Goals

- Navigate native macOS tabs with the standard Command-Shift-Left Bracket and
  Command-Shift-Right Bracket shortcuts.
- Cycle locally among sibling workspaces or sessions with Control-Tab and
  Control-Shift-Tab.
- Apply the same sibling behavior to worktrees, directory workspaces,
  standalone tmux sessions, and Herdr sessions.
- Let users configure Ghosthub-specific shortcuts in both Keyboard Settings
  and `~/.config/ghosthub/config.toml`.
- Make Settings, menus, the command palette, terminal reservation logic, and
  event dispatch use one resolved shortcut registry.
- Stop capturing numbered Command shortcuts by default while retaining
  optional numbered sibling-selection actions.

## Non-goals

- Configuring tmux or Herdr key bindings.
- Sending synthetic navigation keys into tmux or Herdr.
- Configuring standard macOS Edit, Settings, Quit, window, or native-tab
  shortcuts.
- Supporting multi-key chords or multiple alternate bindings for one action.
- Adding recency-based navigation in this change. A separate action can add it
  later without changing sibling-order semantics.

## Navigation Semantics

Ghosthub defines two session-navigation actions:

- **Next Sibling**, default Control-Tab
- **Previous Sibling**, default Control-Shift-Tab

The current sidebar target determines the sibling group:

| Current target | Sibling group |
| --- | --- |
| Worktree | Worktrees in the same repository project |
| Directory workspace | Directory workspaces in the same host's Projects group |
| Standalone tmux session | Standalone tmux sessions on the same host |
| Herdr session | Herdr sessions on the same host |

Navigation uses the persisted sidebar order, excludes items hidden by
configuration, and wraps at either end. Collapsing a disclosure group or
hiding the sidebar does not alter the group because those presentation choices
must not change keyboard behavior. Running and stopped Herdr sessions are both
shown in the sidebar, but only running Herdr sessions are eligible for keyboard
cycling. Selecting a stopped row starts a restart operation, and a navigation
shortcut must not trigger constructive lifecycle work.

If the current target is not session-like, the target is stale, or fewer than
two eligible siblings exist, Ghosthub does not consume the shortcut. The event
continues through the normal responder chain and can reach the active terminal.

Ghosthub explicitly owns the native-tab commands in the Window menu. It
removes or replaces any AppKit-provided Control-Tab and
Control-Shift-Tab equivalents for `selectNextTab(_:)` and
`selectPreviousTab(_:)`, leaving only the fixed Command-Shift-Left Bracket and
Command-Shift-Right Bracket equivalents described below. Therefore Control-Tab
and Control-Shift-Tab always mean Next Sibling and Previous Sibling when those
actions are available. When either action is unavailable or unbound, its event
passes toward the active terminal even if the window contains multiple native
tabs; neither combination changes native tabs as a fallback.

The existing global worktree-cycle actions and their Command-Option-Up Arrow
and Command-Option-Down Arrow defaults are removed. The default Command-1
through Command-9 worktree shortcuts are also removed. Ghosthub retains
**Select Sibling 1** through **Select Sibling 9** as configurable actions with
no default bindings. They resolve through the same sibling group and sidebar
ordering as next and previous navigation.

Native window tabs remain a separate level of navigation:

- **Previous Tab**, fixed Command-Shift-Left Bracket
- **Next Tab**, fixed Command-Shift-Right Bracket

These commands live in the Window menu and operate only on native macOS tabs.
They never change the sidebar selection within a tab.

## Shortcut Registry

A typed registry is the single source of truth for configurable application
shortcuts. Each entry contains:

- A stable action identifier.
- A user-facing name and settings group.
- A compiled default or an unbound default.
- An optional configuration override.
- An availability rule for the focused scene.
- A dispatch action shared by menus, the command palette, and key events.

The first registry includes:

- Next and previous sibling.
- Select sibling 1 through 9.
- Command palette.
- Toggle sidebar.
- New worktree, import pull request, new tmux session, and new Herdr session.
- Split right and split down.
- Reload configuration.
- Open application log.

The compiled defaults are:

| Action | Default |
| --- | --- |
| Next Sibling | `ctrl+tab` |
| Previous Sibling | `ctrl+shift+tab` |
| Select Sibling 1 through 9 | Unbound |
| Command Palette | `cmd+shift+p` |
| Toggle Sidebar | `cmd+b` |
| New Worktree | `cmd+shift+n` |
| Import Pull Request | `cmd+shift+i` |
| New Tmux Session | Unbound |
| New Herdr Session | Unbound |
| Split Right | `cmd+d` |
| Split Down | `cmd+shift+d` |
| Reload Configuration | `cmd+shift+,` |
| Open Application Log | `cmd+opt+l` |

Standard macOS shortcuts remain outside this registry. This includes native
tab and window commands, Settings, Quit, Close, and Edit commands.

The shortcut and action types stay independent of AppKit where practical so
parsing, validation, resolution, and display formatting can be tested without
opening an application window. AppKit adapters translate between the neutral
model and `NSEvent` or menu equivalents.

## Configuration

Shortcut overrides use a dedicated TOML table:

```toml
[keyboard.shortcuts]
next-sibling = "ctrl+tab"
previous-sibling = "ctrl+shift+tab"
command-palette = "cmd+shift+p"
select-sibling-1 = "cmd+1"
split-right = "none"
```

Configuration rules:

- A missing key uses the compiled default.
- `"none"` explicitly unbinds the action.
- One action accepts one binding.
- Parser input is case-insensitive and Settings writes normalized lowercase
  names.
- Supported modifiers are `cmd`, `ctrl`, `opt`, and `shift`.
- Supported keys include letters, digits, punctuation, arrows, Tab, Return,
  Escape, and function keys.
- Every configurable binding must include at least one non-Shift modifier:
  `cmd`, `ctrl`, or `opt`. Shift alone does not satisfy this rule. This rejects
  bare and Shift-only printable keys, Tab, Backtab, arrows, Return, Escape, and
  function keys so Ghosthub cannot accidentally intercept ordinary terminal
  or text input.
- Fixed macOS shortcuts are reserved and cannot be assigned.
- Two actions cannot have the same effective binding.
- Unknown shortcut keys are preserved for forward compatibility but do not
  create runtime actions.

Manual configuration validation is atomic. If a known shortcut is malformed,
reserved, or duplicated, Ghosthub keeps the last valid resolved set. During
process startup, there is no hidden persisted last-valid cache: an invalid
shortcut table causes the entire registry to use compiled defaults until the
file is fixed and reloaded. Ghosthub reports the exact error in
Keyboard Settings and the application log without rewriting the invalid file.
This intentionally means a bad live reload retains the current valid set while
relaunching with the same bad file starts from defaults.

Settings writes only the affected shortcut key and preserves comments,
unknown keys, line endings, and unrelated TOML sections. Restore Default
removes the override. Clear writes `"none"`.

## Keyboard Settings

The Keyboard pane becomes an editor with four sections:

1. **Navigation**: sibling cycling and numbered selection.
2. **Application**: command palette, sidebar, creation, reload, and log.
3. **Multiplexer**: split right and split down.
4. **System Shortcuts**: read-only native tab, window, Settings, Edit, and Quit
   bindings.

The read-only native-tab rows show only Command-Shift-Left Bracket and
Command-Shift-Right Bracket. They do not advertise Control-Tab alternatives;
those combinations belong to configurable sibling navigation and terminal
pass-through.

Each configurable row shows the action name and a shortcut recorder. Clicking
the recorder enters recording mode. The next valid combination updates the
draft. Escape cancels recording, Clear selects the unbound state, and Restore
Default removes the override.

Invalid input remains visible with a specific inline explanation, for example:

- `Already used by Toggle Sidebar.`
- `Reserved for Next Tab.`
- `Add a modifier to avoid intercepting terminal input.`

Shortcut edits follow the existing Settings lifecycle. They remain in the
Settings draft and persist when the sheet closes. The resolved registry then
updates atomically, so runtime consumers never observe a partially edited set.

The recorder exposes accessibility labels for the action, current binding,
recording state, Clear and Restore Default controls, and any validation error.

## Menus and Command Palette

Menus and the command palette read titles, effective shortcut labels,
availability, and dispatch behavior from the registry. An unbound action
remains available through these discovery surfaces without showing a key
equivalent.

The Window menu supplies fixed Previous Tab and Next Tab commands. The Session
menu supplies Next Sibling, Previous Sibling, and any other navigation actions
appropriate for direct discovery. Other existing menu locations retain their
actions but display the configured effective binding. Ghosthub suppresses
AppKit-provided Control-Tab equivalents for native tab selection so the Window
menu advertises and dispatches only the fixed bracket bindings.

Every command-palette shortcut label comes from the registry. Import Pull
Request joins the registry with a real Command-Shift-I default and dispatch
path. The unused Command-Shift-Delete shortcut case is removed. No command may
display a shortcut that the application does not dispatch.

Reload Configuration reloads and validates the shortcut table along with the
other Ghosthub configuration. A successful reload publishes the entire
resolved registry at once.

## Runtime Dispatch

The focused workspace scene exposes whether each action is available and a
single execution path for it. The shortcut monitor:

1. Converts an incoming event to the neutral key-binding model.
2. Looks it up in the resolved registry.
3. Asks the focused scene to perform the matching action.
4. Consumes the event only when the action succeeds.

An unavailable, unbound, or unmatched event passes through unchanged. This is
especially important for Control-Tab because tmux, Herdr, or a program inside
the session may use it when Ghosthub has no sibling to select.

The terminal's application-shortcut reservation logic uses the same resolved
registry for Command-modified configurable actions. This prevents libghostty
from claiming an application shortcut while avoiding a second hard-coded
shortcut list. Fixed system shortcuts remain explicitly reserved through the
native application commands.

Ghosthub changes only its own selection and presentation. It does not alter
tmux or Herdr configuration, reconstruct multiplexer state, or synthesize
multiplexer navigation commands.

## Navigation Resolution

`KeyboardNavigationModel` owns sibling resolution. Given the snapshot, current
selection, visibility preferences, persisted sidebar orders, direction or
index, it returns the selected `WorkspaceNavigationTarget` or no result.

This operation reuses sidebar-model grouping and ordering rather than
maintaining parallel rules. Next, previous, and numbered selection all call the
same resolver. App event dispatch and command-palette invocation also call the
same operation, so invoking an action through a menu cannot differ from its
keyboard binding.

## Testing

Unit and integration coverage verifies observable contracts:

- Key-binding parsing, normalization, display formatting, defaults, explicit
  unbinding, reserved combinations, and duplicates.
- Bare and Shift-only combinations fail validation, including Shift-Tab.
- The complete compiled-default table matches effective menu and
  command-palette bindings.
- Targeted TOML edits preserve comments, unknown keys, unrelated sections, and
  line endings.
- Invalid manual configuration keeps the last valid set during a live reload
  and uses the complete compiled-default set after a fresh process launch.
- Sibling resolution covers worktrees within one repository project, directory
  workspaces within one host's Projects group, standalone tmux sessions, and
  running Herdr sessions while excluding stopped Herdr sessions.
- Sidebar order, hidden items, wrapping, stale targets, and zero or one sibling
  behave as specified.
- Numbered selection uses the same local groups.
- Only the focused window dispatches an application shortcut.
- Control-Tab is consumed when navigation succeeds and reaches the terminal
  when navigation is unavailable or unbound.
- Menus and command-palette labels update from the resolved registry.
- The recorder validates input and supports Clear, Restore Default, and
  accessible operation.
- Command-Shift-Left Bracket and Command-Shift-Right Bracket navigate native
  tabs.
- Control-Tab and Control-Shift-Tab never select native tabs: they select an
  available sibling or pass toward the terminal when sibling navigation is
  unavailable or unbound, including in a window with multiple native tabs.
- AppKit-provided native-tab items do not retain Control-Tab equivalents.
- Import Pull Request has a real Command-Shift-I action, and no palette command
  advertises a shortcut without a dispatch path.

Because the implementation changes Swift UI, terminal key handling, and native
session selection, verification includes:

- `make format`
- `make test-libghostty-bootstrap`
- `make python-test`
- `swift test`
- `make test-essential-workflows`
- `make build`

## Documentation and Acceptance

The website Keyboard Shortcuts guide will document:

- Fixed native tab navigation.
- Local sibling groups and sidebar-order wrapping.
- Configurable versus fixed application shortcuts.
- Keyboard Settings recorder behavior.
- The `[keyboard.shortcuts]` TOML format and `"none"` value.

At feature acceptance, capture Keyboard Settings with deterministic synthetic
demo data if the implemented view materially changes the published screenshot
set. Publish any required refreshed image through the `website-assets` branch
before a pull request is opened.

This design document is a local planning artifact. It must be removed from the
task branch before opening or updating a pull request.
