# Flat Sidebar Design

Status: approved direction, pending spec review.
Mockups: reviewed interactively during design; this spec records every
decision they settled.
Scope: the macOS Swift app. The Rust port sidebar is a separate follow-up.

## Goal

Make the left sidebar flatter and quieter. Hosts are the only level of
hierarchy. Each host lists all of its multiplexer sessions (tmux, Zellij,
Herdr desktop terminals, Herdr TUI sessions) in one list, with a small label
that names the backend. Projects and worktrees keep their place below the
sessions.

Today each host shows up to five collapsible sections (Tmux Sessions, Herdr
Terminals, Herdr TUI Sessions, Zellij Sessions, Projects). Each has its own
header, `+` button, and two-line rows with an icon. On the demo fixture that
is 11 header rows for 12 sessions.

## Layout

Each host renders, top to bottom:

1. **Host header.** Host name (semibold, small), dimmed detail line (for
   example the SSH alias), and a connection dot. A disclosure chevron and a
   `+` button appear on hover or keyboard focus. The existing inventory
   warning button stays. The tinted header band and its bottom rule are
   removed.
2. **Sessions.** One list of every session on the host, sorted by the
   chosen sort mode (see Sorting). No group header.
3. **Projects.** A quiet "Projects" label, then each project as a
   collapsible label row: project name plus its dimmed path. Worktree rows
   sit under their project. Directory workspaces stay after the projects as
   today. The inset tinted box and leading rail around projects are removed.

The vertical guide line beside host contents is removed. Spacing between
hosts separates them.

Disclosure keys reduce to `host:`, `projects:`, and `project:`. The
`sessions:`, `herdr-sessions:`, `herdr-terminals:`, and `zellij-sessions:`
keys go away.

## Rows

Every session and worktree row is one line. Rows carry no leading icon and no
subtitle.

Session row, left to right:

- **Preview chevron**, only when the row can show a session preview and
  previews are not Off. Rows that cannot preview reserve no chevron space
  when previews are Off; when previews are on, non-previewable rows reserve
  the slot so names stay aligned.
- **Name**, 13 pt, truncates at the end. Herdr desktop terminals show their
  `space / tab` name with the space part dimmed.
- **Stopped** marker for stopped Herdr TUI sessions. The row text is dimmed.
- **Agent badge**, unchanged in color, symbol, and motion.
- **Backend label**, the fixed last column (see Backend label).
- **Actions (⋯)** on hover, selection, or focus. It replaces the backend label
  in the same slot so the row never shifts. It opens the same actions as the
  row's context menu.

Worktree row: preview chevron, branch name, agent badge, then the existing
git status (diff `+N −N`, ahead/behind, PR number, checks glyph) on the same
line. The current second PR line is folded into this single line; the PR
title stays in the tooltip and the detail card. Worktree rows show no backend
label because they are always tmux.

Window count, "Running", "Zellij session", and similar subtitles are
removed. The window count moves to the row tooltip.

Selection is a soft accent fill with no border. Hover is a faint fill.

## Backend label

Labels: `tmux`, `zellij`, `herdr` (Herdr desktop terminal), `herdr tui`
(Herdr TUI session). Rex gets a label when its backend lands; nothing ships
for Rex now.

Each backend has its own hue, defined once as a named color. The hues are
chosen to stay distinct from the agent attention colors (orange approval,
purple input, green working and done) so a label never reads as an alert.
Mockup values: tmux teal, Zellij gold, Herdr blue. Final values are tuned for
contrast in light, dark, and increased-contrast appearances.

Three styles, chosen in Settings:

- **Chip** (default): small monospaced lowercase text on a low tint
  (about 12%) of the backend hue, slightly stronger on the selected row, no
  border.
- **Text**: the same text in the backend hue with no background.
- **Dot**: a 6 pt dot in the backend hue before the name and no trailing
  label. The backend name moves to the tooltip and the accessibility label.

In every style the accessibility label states the backend, for example
"docs-preview, Zellij session".

## Host `+` menu

One `+` on the host header replaces the four per-section `+` buttons. Its
menu:

- New tmux Session…
- New Zellij Session…
- New Herdr Session… (creates a Herdr TUI session)
- separator
- Add Project…

A backend that is unavailable on the host stays in the menu, disabled, with
the reason as its tooltip. Add Project… follows the existing
`canRegisterProjects` rule. New Worktree… and Import Pull Request… stay on
each project's own `+`.

## Sorting

A sort mode applies to the session list of every host:

- **Manual** (default): one drag order across all backends. Drag to reorder
  works only in this mode.
- **Name**: localized standard compare on the displayed name.
- **Backend**: tmux, Zellij, Herdr desktop terminals, Herdr TUI sessions,
  then name.
- **Needs attention**: sessions waiting on input or approval first, then
  working, then done, then the rest, each in manual order.

In every mode, stopped Herdr TUI sessions sink to the bottom.

No backend reports last-activity time, so there is no "recent activity"
mode.

Manual order uses one new key, `workspaceSidebarSessionOrderV2`, holding the
existing per-backend order IDs (`tmuxSessionOrderID`, `herdrSessionOrderID`,
`zellijSessionOrderID`). It replaces `workspaceSidebarTmuxSessionOrderV1`,
`workspaceSidebarHerdrSessionOrderV1`, and
`workspaceSidebarZellijSessionOrderV1`. Sessions missing from the stored
order fall back to Backend order. The old keys are not read or migrated;
Ghosthub is alpha and custom drag orders reset once. Rename keeps a renamed
tmux session at its saved position, as today.

The sort mode is set from two places that write the same stored value:

- a sort menu button in the sidebar header next to "Workspaces", showing the
  current mode, and
- Settings › Sidebar.

## Keyboard navigation

Next and previous session walk the host's merged session list in displayed
order, skipping stopped Herdr TUI sessions. Today they stay within one
backend group. Worktree navigation is unchanged.

## Settings › Sidebar

A new Settings pane, **Sidebar**, placed after Appearance. It collects every
sidebar option, including the three toggles that live under Worktrees ›
Sidebar Behavior today.

**Live preview.** The top of the pane shows a sample sidebar: one sample
host with a mix of sessions (tmux with agent badges, Zellij, a Herdr desktop
terminal, a Herdr TUI session, a stopped Herdr session, a session that
belongs to a worktree) and one sample project with a root checkout, a
worktree with PR status, and a hidden worktree. The preview renders the
draft settings with the same row views the real sidebar uses, so it cannot
drift from the real sidebar. Rows affected by the last change briefly
highlight (no animation with Reduce Motion). A note beside it says changes
apply when you click Done, matching how Settings saves today.

**Layout group:**

- Backend label: segmented control, Chip, Text, Dot. Each segment carries a
  tiny sample of its style.
- Row height: segmented control, Regular (28 pt), Compact (24 pt).
- Sort sessions by: pop-up menu, Manual, Name, Backend, Needs attention.
  Footnote: "Also in the menu at the top of the sidebar."

**Contents group** (moved from Worktrees):

- Hide sessions that belong to a worktree (today "Hide kwt-managed sessions
  from Tmux Sessions"; the section it names no longer exists). Footnote:
  "They stay available under their project."
- Hide the root checkout.
- Show hidden worktrees.

New settings live in `SettingsStore` beside the existing sidebar toggles and
flow through `SettingsViewDraft`. The header sort menu writes the stored
value directly. If Settings is open, its draft keeps the value it loaded, and
Done saves the draft's value.

## Code shape

- `WorkspaceSidebarSection` replaces `tmuxSessionRows`, `herdrSessionRows`,
  and `zellijSessionRows` with one `sessionRows` array, built and sorted in
  `WorkspaceSidebarModel.sections`. `WorkspaceSidebarRow` gains a backend
  value used for the label and the accessibility label.
- `WorkspaceSidebarGroup` and `visibleGroups` collapse to sessions and
  projects; consumers (`KeyboardNavigationModel`, `CommandPaletteModel`)
  move to `sessionRows`.
- `WorkspaceSidebarSectionActionModel` becomes the host menu model.
- `WorkspaceSidebarView` splits row rendering into a small session row view
  and worktree row view that both the sidebar and the Settings preview use.
  This also shrinks the 2,600-line view file.
- A new sort mode type with the four cases, tested as a pure function.

## Docs

Update the section-based wording in `AGENTS.md`, `docs/architecture.md`,
`docs/terminal-sessions.md` (including "sibling navigation stays within each
group"), and the website Guide pages that name sidebar sections
(`sessions.md`, `getting-started.md`, `projects-worktrees.md`,
`keyboard-shortcuts.md`, `launch-profiles.md`, `troubleshooting.md`).
Screenshots are regenerated at feature acceptance, per the repository rules.

## Testing

- Model: merged order for each sort mode; stopped Herdr sinks in every mode;
  a manual drag across backends; sessions missing from the stored order fall
  back to Backend order; pruning removes vanished sessions; rename keeps
  position.
- Keyboard navigation: next/previous across backends in display order,
  skipping stopped Herdr sessions.
- Settings: draft round-trip for the three new settings; the moved toggles
  keep their stored keys and behavior.
- Existing sidebar view and accessibility tests updated for the new
  structure and identifiers.
- Gates: `make format`, `make build`, `make swift-test`,
  `make test-essential-workflows`.

## Out of scope

- The Rust port sidebar (kata follow-up).
- Configurable placement of worktree sessions (listing them among host
  sessions).
- Rex backend support.
- Recently opened sort mode.
