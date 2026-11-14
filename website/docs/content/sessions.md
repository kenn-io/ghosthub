---
description: Create, open, preview, and end tmux, Herdr, Rex, and Zellij sessions.
icon: lucide/square-terminal
---

# Sessions

Open a running session, create one for a new task, or return to work started by
your tools and agents. Closing a Ghosthub terminal leaves its session running.

Expand a host in the sidebar to find its sessions. Each host shows one list of
sessions, then a **Projects** group:

- The session list holds every session that is not grouped under a project.
  A label at the end of each row names its backend:

  | Label | Session |
  | --- | --- |
  | **tmux** | tmux session |
  | **zellij** | active Zellij session |
  | **herdr** | live Herdr desktop terminal (macOS) |
  | **herdr tui** | running or stopped session from the older Herdr terminal app |
  | **rex** | terminal on a running Rex server (macOS) |

- **Projects** lists Git worktrees and registered directories with tmux sessions.

If Herdr, Rex, or Zellij is not installed, its sessions simply do not appear.
You can use several multiplexers on the same host. Each keeps its own panes,
layout, history, key bindings, and running programs. To change how the labels
look or how the list is sorted, see [Arrange the session list](#arrange-the-session-list).

![Ghosthub showing tmux, Herdr, and Zellij sessions in one labeled list, with an active Zellij session and its Command Palette actions](/docs/assets/guide-sessions.png)

## Sessions started by tools and agents

Use the same session from Ghosthub and your command-line tools. On a configured
host, an agent can create an ordinary tmux, Herdr, or Zellij session and you can
select it in Ghosthub's sidebar. No Ghosthub-specific launch command is needed.
Herdr and Zellij sessions started elsewhere appear within about 30 seconds
while Ghosthub is active and the host is connected.

For example, create a detached tmux session on your Mac or SSH host:

```sh
tmux new-session -d -s agent-review
```

Select **agent-review** in that host's session list. The agent and your
terminal share the same running session. Closing Ghosthub leaves it running.

For project work, agents can run `kwt list --json` from a repository to inspect
its worktrees and their exact session names. Kwt-managed sessions use
the server described below. Ghosthub's manual worktree flags are reminders on
this Mac; they do not report agent progress.

## Find tmux sessions on kwt's server

Ghosthub checks the default tmux server and kwt's server. Sessions registered
as worktrees or directories appear under **Projects**. Other sessions on either
server appear in the host's session list, including those created with
`kwt tmux run`. Ghosthub opens each session on the server where it was found.
It does not scan arbitrary named tmux servers.

Use tmux's window chooser, normally prefix then `w`, to switch windows inside
a session. To list sessions on kwt's server from a shell, run:

```sh
env -u TMUX_TMPDIR tmux -L kwt list-sessions
```

Kwt uses its own socket directory even if your shell sets `TMUX_TMPDIR`.
Ghosthub's macOS app follows that rule. The default server continues to use
your shell's socket directory.

If Ghosthub cannot read the kwt server, it shows a warning beside the host.
Default-server sessions still refresh. Kwt rows keep their last known state
until discovery succeeds again.

## Create a standalone session

1. Select the **+** at the right end of the target host's row in the sidebar.
2. Choose **New tmux Session…**, **New Zellij Session…**, or
   **New Herdr Session…**.
3. Enter a session name.

A backend that is not available on the host stays in the menu, dimmed. Hover
over it to see why.

A new tmux session remains usable from the `tmux` CLI and other tmux clients.
To start a remote session with a saved command, use a
[launch profile](launch-profiles.md).
A new Herdr session is created with Herdr's own launch path and Ghosthub
attaches immediately. Its creation action appears only when the host's
`herdr session list --json` capability is available. A TUI session name already
present in either running or stopped state is
rejected; restart a stopped session instead.

A new Zellij session uses Zellij's new-session path and remains an ordinary
Zellij session. Active and resurrectable names are both rejected. Ghosthub
lists only active sessions and does not expose resurrection as a workflow.

## Herdr desktop terminals

Ghosthub on macOS can open live terminals from the newer
[Herdr desktop app](https://github.com/herdrdev/herdr-app). This uses
[herdr-core](https://github.com/herdrdev/herdr-core), which stores terminals
separately from older Herdr TUI sessions. Windows and Linux builds do not yet
include this integration.

Each terminal opens on its own. Ghosthub does not display Herdr desktop's
spaces, tabs, or [split layout](#herdr-desktop-splits).

1. Install `herdr-core` on the Mac or SSH host where the terminal runs. Its
   executable must be on that account's login-shell `PATH`. The upstream
   installer places it in `~/.local/bin`; `hc` is an optional alias.
2. Start a terminal in Herdr desktop, or run `herdr-core run --bg --name review`.
3. Find the terminal's **herdr** row in the host's session list and select it.
   The row shows its name or desktop space and tab, followed by its address
   (such as `t7`).
   You can also press ++shift+cmd+p++ and search for the name or address.

![A Herdr desktop terminal and an older Herdr TUI session in one host's session list.](/docs/assets/guide-herdr-core.png)

Switching away or pressing ++cmd+w++ detaches and leaves the program running.
Press ++ctrl+tab++ or ++ctrl+shift+tab++ to move to the next or previous
session in the host's list. Herdr desktop's space, tab, and pane
shortcuts belong to its own window.

Create terminals in Herdr desktop or with its CLI. Ghosthub's
**New Herdr Session…** action and the Stop, Restart, and Delete actions apply
only to the older Herdr TUI app.

Ghosthub checks the default core on each configured host. It excludes finished
terminals and terminals reached through core's own remote-machine connections;
add those machines as Ghosthub SSH hosts instead. Named `HC_SESSION` instances
and `HC_SOCKET` overrides are not selected. Like an ordinary CLI invocation,
`herdr-core ls` can start the default core if it is not running.

Agents use the same terminals through `herdr-core ls --json`,
`herdr-core read t7`, and other upstream CLI commands. Ghosthub keeps the
terminal address separate from its display name, so renaming a terminal does
not change the attachment target. Agents can inspect the desktop's arrangement
with `herdr-app ls`; its terminal addresses match `herdr-core ls --json` and
Ghosthub. The desktop handoff is tested with Herdr 0.1.13 and core 0.1.17.

### Herdr desktop splits

Each terminal pane in a Herdr desktop split appears as a separate **herdr**
row in the host's session list. A tab with two terminal panes produces two rows. Selecting
either row opens that terminal at full size. Ghosthub does not show the panes
side by side or preserve their arrangement.

Without explicit terminal names, panes in the same desktop tab share the same
`space / tab` title. Use the address after each title, such as `t1` or `t2`,
to tell them apart. ++ctrl+tab++ and ++ctrl+shift+tab++ move through every
session in the host's list, including terminals in other tabs.

Use Herdr desktop to view or change the split layout. Ghosthub's **Split Right**
and **Split Down** actions are unavailable for desktop terminals. Older
Herdr TUI sessions open as a whole session, including their visible splits.

## Rex terminals

Ghosthub on macOS can open terminals from a running
[Rex](https://www.superlogical.com/rex/docs) server on your Mac or an SSH host.
Each Rex terminal block opens on its own, at the size of the Ghosthub window.
Ghosthub does not display Rex's windows or split layout.

1. Install Rex Server and start it, for example by opening Rex. Ghosthub never
   starts a stopped Rex server.
2. Start a terminal in Rex, or run `rex run -- htop`.
3. Expand the host in Ghosthub and select the terminal's **rex** row. The row
   shows the name Rex shows, such as `zsh ~`, followed by its Rex session and,
   when needed, its window and pane number. You can
   also press ++shift+cmd+p++ and search for it.

Switching away or pressing ++cmd+w++ detaches and leaves the program running.
Press ++ctrl+tab++ or ++ctrl+shift+tab++ to move to the next or previous session
in the host's list. If the program exits, **Reconnect** closes the terminal's page
instead of reopening it.

Ghosthub reaches Rex through its own copy of kwt, so you do not need to install
anything else. On an SSH host, it uses the
[managed kwt helper](remote-hosts.md#managed-kwt-helper) that Ghosthub keeps up
to date there. Create, split, and close Rex terminals in Rex or with the `rex`
command.

## Attach and detach

Select a running tmux, Herdr, or Zellij session in the sidebar, or search for it in the Command
Palette with ++shift+cmd+p++. Ghosthub opens an ordinary local or SSH client
for the selected backend. Herdr TUI receives the complete terminal and continues
to own its workspaces, tabs, panes, history, and key bindings. Herdr desktop
attachments open individual terminals as described above.

On macOS, selecting an existing session with Zellij 0.45
attaches directly instead of opening its session chooser. Names beginning
with `-` (except `-` alone), `help`, and `options` cannot be created or attached
because Zellij reads them as options or commands. Existing sessions with
those names remain visible and can still be killed after confirmation.

For POSIX tmux sessions, Ghosthub enables tmux mouse mode on attachment. Wheel
scrolling therefore opens and navigates tmux copy mode even when the session
uses tmux's vanilla configuration. Mouse mode is a shared session option, so
other attached clients see it too; tmux's own mouse bindings remain in charge.
Native Windows/psmux keeps its existing mouse-reporting limitation.

Switching to another host, worktree, or session hides an opened tmux terminal
without detaching it. Each workspace keeps every tmux session you explicitly
open connected, and returning to one reuses the same terminal and client.
Switching away from Herdr or Zellij detaches its presentation; the server and
its processes continue running.

Zellij does not provide an atomic active-only attach command. Ghosthub checks
that a selected session is active before attaching and does not offer
resurrection, but Zellij may resurrect its saved layout if the session exits in
the brief interval before the client command resolves it. Ghosthub does not
request automatic execution of resurrected commands.

Press ++cmd+w++ to detach only the active presentation. Closing a workspace
tab or window detaches every presentation it owns, and quitting Ghosthub
detaches them all. None of these actions ends a tmux session or stops a Herdr
or Zellij server. A normal Herdr or Zellij detach offers **Reconnect** and does
not retry automatically.

## Recover a connection

On a remote host, a dropped SSH connection starts automatic recovery. Ghosthub
probes the same exact session before each replacement client. Retry stops when
the session disappears, Herdr becomes unavailable, or the client reports a
non-transport failure. **Reconnect Now** skips the current delay; host-key or
authentication problems open the connection review. See
[Automatic reconnect](remote-hosts.md#automatic-reconnect) for controls and errors.

After relaunch, Ghosthub restores a remote Zellij session only while the
selected SSH route still matches. If SSH settings change during that check,
restoration stops instead of connecting to a different host.

If macOS wakes while no display is active, Ghosthub waits instead of treating
the missing terminal surface as a permanent attachment failure. Recovery
resumes when a display becomes available, without replaying a saved tmux
launch-profile command.

## Paste text or images and open links

Use **Command-V** to paste. For image files, text precedence, and cleanup, see
[Clipboard behavior](terminal-configuration.md#clipboard-behavior).
**Control-V** passes through to the terminal program.

Hold **Command** and click a highlighted terminal link to open it in the
default macOS application.

## Find text in a terminal

Press **Command-F** or choose **Find in Terminal** in the Command Palette.
Search covers the active pane's full history in a standalone terminal or a
macOS or Linux tmux 3.4+ session. Herdr, Zellij, Windows/psmux, and older tmux
versions do not support Find.

**Return** or **Command-G** goes toward older matches. **Shift-Return** or
**Shift-Command-G** goes toward newer matches. **Escape**,
**Shift-Command-F**, or the close button ends Find.

Standalone terminal search does not wrap. Tmux controls wrapping and the
first step after a direction change. Its copy mode is shared by the pane, so
another attached client can see or cancel the search.

![Find bar searching an active tmux pane's history](/docs/assets/guide-find.png)

## Preview opened tmux sessions

Choose **Settings → Terminal → Session previews**, then select **Efficient**,
**Live**, or **Always Live**. Select **Done** to apply the mode.
Efficient and Live add a disclosure control beside
tmux sessions that you have already opened in that workspace. Expand it to show
a preview of the terminal. Always Live connects every freshly discovered tmux
session on every reachable POSIX host and expands its tile automatically. Each
tile follows its terminal's aspect ratio, preserving the complete frame
without cropping.
Selecting the preview follows the same route as selecting its session row.

![Ghosthub sidebar showing Always Live previews expanded for discovered tmux sessions](/docs/assets/guide-session-previews.png)

The modes trade resource use for freshness:

- **Off** is the default. It hides preview controls, clears cached frames, and
  avoids preview GPU work.
- **Efficient** captures when you expand a preview and when its tmux
  presentation stops being active. It does not refresh in the background.
- **Live** refreshes expanded previews at no more than two frames per second.
  Across the app, at most four inactive tmux surfaces can render live at once;
  an additional tile reports that the live-preview limit was reached.
- **Always Live** connects every freshly discovered tmux session on POSIX
  hosts, expands its preview automatically, and refreshes all expanded tiles
  without the four-surface limit. This can use substantial CPU, GPU, memory,
  and SSH capacity. Collapse a tile to stop rendering it while keeping its
  client connected. Ghosthub starts the clients incrementally, so earlier
  tiles can appear while a large session fleet is still connecting.

Expansion choices stay in memory for each workspace window, including while
the mode is Off, and reset when that window closes. Hiding the sidebar or
briefly switching away from Ghosthub stops live rendering until it is visible
and active again. Always Live keeps its automatically opened clients connected during
that pause.

Efficient and Live preview only sessions you opened. Always Live adds a tmux
client for each discovered session on reachable macOS and Linux hosts.
Switching away from Always Live detaches only clients it opened automatically.
Opening a preview lets you use that same client interactively.

Previews require tmux 3.4 or newer. Always Live skips automatic attachment
when setup fails or that version is unavailable; you can still open the
session normally. Windows/psmux sessions are not attached automatically.
Preview tiles do not resize the underlying tmux window.

During reconnect, a placeholder replaces the old frame until Ghosthub
confirms it has reached the same session. Detaching the client or finding a
replacement session with the same name removes its preview.

## Activity indicators

After a session connects, Ghosthub remembers it for the rest of the app
launch. A small accent indicator appears beside its worktree or standalone
session row when Ghosthub observes recent tmux scrollback progress, then
clears about thirty seconds after output stops.

![Ghosthub sidebar showing an accent activity indicator beside a standalone session that is producing output while another session is selected](/docs/assets/guide-session-activity.png)

Only genuine output counts. Switching panes, resizing the window, or a
full-screen tool redrawing its prompt, spinner, or status display does not
light the indicator. Closing the window still only detaches; the warm session
stays visible across your other Ghosthub windows.

This activity state resets when Ghosthub quits. Ghosthub never scans sessions
you have not opened, and terminal text never leaves the host: the probe
returns only a checksum and size counters. On native Windows hosts, activity
indicators require psmux 3.3.4 or newer.

## Agents waiting for you

A tmux session running a coding agent shows what the agent is
doing at the right edge of its sidebar row:

- **Approval** (amber bubble): the agent is waiting for permission.
- **Input** (purple bubble): the agent asked you a question.
- **Done** (green dot): the agent finished a turn you have not looked at.
- **Working** (pulsing green dot): the agent is busy.

The native tab whose current session needs you shows the same icon beside its
shortcut. Hover a badge to see which agent it is.

![Ghosthub sidebar with Approval, Input, Done, and Working badges on four tmux sessions](/docs/assets/guide-agent-attention.png)

**Done** clears once you view that session in the front window. **Approval**
and **Input** stay until the agent continues.

To turn this on for a host:

1. Open **Settings → Hosts** and select the local Mac or a remote host.
2. Under **Agent Hooks**, click **Install Hooks**.
3. In Codex, open `/hooks` once to trust the new hooks.

Ghosthub installs hooks for each supported agent already set up on that host,
including Claude Code, Codex, Gemini CLI, and Cursor. Badges refresh when you
switch to Ghosthub and about every thirty seconds while it stays in front.
Native Windows hosts and Herdr and Zellij sessions do not show agent
badges yet.

## Reopen an exited standalone session

If a standalone session exits while its presentation is still open, Ghosthub
shows a **Reopen** action. Reopening creates a new tmux session with the exact
previous name. It cannot restore processes from the exited session.

A clean detach or a confirmed ended session stays closed until you explicitly
open or reopen it.

## Rename a standalone session

Open a standalone session row's **⋯** menu, or Control-click the row, and
choose **Rename Session…**, or use
**Rename tmux session** in the Command Palette. The new name must be unique on
that host and cannot contain periods, colons, or line breaks. An open session
stays connected in every window that shows it and keeps its windows, panes, and
processes. If the session is still connecting in the window you rename from,
wait a moment and try again.

![Rename tmux session sheet with the current session name ready to edit](/docs/assets/guide-session-rename.png)

Sessions that kwt manages for worktrees and directories keep the names kwt
assigns, so they have no rename action. For the same reason, a new name cannot
start with `kwt-wt-` or `kwt-workspace-`.
Renaming is unavailable on native Windows hosts.

## End a session deliberately

Every session row has a small **⋯** menu just after its backend label. It
appears when you hover over the row and stays visible on the selected row. To
end a standalone tmux or active Zellij session, open that menu, or Control-click
the row, and choose **Kill Session…**. For a kwt-backed session, open its
worktree's **…** menu, or Control-click the row, and choose **Kill Session…**.

Ghosthub confirms the host and exact tmux session before it sends
`kill-session`. Ending a session terminates all of its windows, panes, and
processes and cannot be undone.

For tmux, Ghosthub cancels the operation if the host connection changes, or if the
original session disappears and another session appears under the same name.
If the command fails, the active attachment remains open.

Herdr lifecycle is whole-session only:

- A running row offers **Stop Session…**. After confirmation, every shell,
  agent, server, test, and other process ends, while Herdr retains the saved
  workspace/tab/pane shape.
- A dimmed **stopped** row offers **Restart**, which restores that shape with
  new processes and attaches immediately.
- A stopped named row also offers **Delete Session…**, which permanently
  removes its saved state after confirmation.
- Herdr's default session may be stopped and restarted, but never deleted.

These actions are also in the Command Palette. Ghosthub suppresses reconnect
across every open scene while an intentional stop runs, so another window does
not silently resurrect the session.

An active Zellij row offers **Kill Session…**. Ghosthub confirms the host and
name, rechecks that exact active session immediately before the command, and
then asks Zellij to kill it. While the kill is running, Ghosthub detaches that
session and suppresses same-session reconnects in every open scene so neither
an existing client nor an automatic reconnect can undo the intentional kill.
Successful kills also remove the row from every open scene and refresh Zellij
inventory. If the kill fails, an eligible detached presentation or matching
pending open or restoration is rechecked before it resumes. Zellij does not
provide tmux-style stable session identity, so a same-name replacement between
the final check and command is an accepted race. Ghosthub never offers
resurrection or deletes exited Zellij sessions.

!!! warning "Killing a session is different from removing a worktree"

    **Kill Session…** ends tmux processes but keeps the checkout. Removing a
    worktree ends its verified live session when necessary and then removes the
    checkout, while keeping the Git branch. See
    [Remove a worktree](projects-worktrees.md#remove-a-worktree).

## Arrange the session list

Select the options menu (the stacked lines beside **Workspaces** at the top of
the sidebar) and choose how to order every host's session list:

- **Manual** keeps the order you set by dragging rows. Drag a row onto another
  row to move it, across backends too. Sessions you have not placed yet appear
  after the placed ones, grouped by backend.
- **Name** sorts sessions alphabetically.
- **Backend** groups tmux, Zellij, Herdr desktop, and Herdr TUI sessions, each
  by name.
- **Needs Attention** moves sessions whose agent is waiting for approval or
  input to the top, then working agents, then finished turns. Other sessions
  keep their manual order.

Stopped Herdr sessions always sit at the bottom. ++ctrl+tab++ and
++ctrl+shift+tab++ follow the same order. While a sort other than **Manual** is
on, the options menu icon shows in the accent color.

The same menu changes the rest of the sidebar's settings at once:

- **Backend Label**: a **Chip** (the default), colored **Text**, or a small
  colored **Dot** before the name.
- **Row Height**: **Regular** or **Compact**.
- **Hide Worktree Sessions**, **Hide Root Checkout**, and **Show Hidden
  Worktrees**.

To compare choices before you apply them, select **Sidebar Settings…** in the
menu or open **Settings → Sidebar**. A sample sidebar at the top of the pane
shows each choice. Select **Done** to apply your changes.

## Hide standalone sessions

To keep tool-owned or noisy standalone sessions out of the sidebar:

1. Open **Settings → Worktrees**.
2. Add hidden tmux session patterns, one per line.

Patterns are case-sensitive. `*` matches any number of characters and `?`
matches one character. Ghosthub stores these patterns in
`~/.config/ghosthub/config.toml`.

The patterns apply only to standalone sessions. A matching kwt workspace stays
visible under its project.

Kwt-managed sessions are also omitted from the host's session list by default
because their worktrees remain the canonical entry. To show those duplicate
session rows, turn off **Hide Worktree Sessions** in the sidebar's options
menu. The worktree's status glyph continues to reflect the live tmux session either way.

## Ownership and safety

Ghosthub does not infer that closing a presentation means ending work. It
destroys a tmux session only after an explicit, confirmed **Kill Session**
action or as part of confirmed worktree removal when that worktree has a
verified live session. Sessions created outside Ghosthub receive the same
protection as sessions created inside it. For Herdr, Ghosthub manages only
whole-session create, stop, restart, and delete, plus the explicit Split Right
and Split Down requests against a connected Herdr 0.8.0-or-newer session. Herdr
selects the focused pane and continues to own themes, workspaces, tabs, panes,
agents, plugins, configuration, updates, and internal process behavior.
For Zellij, Ghosthub manages only active-session create, attach, and confirmed
kill. Zellij continues to own tabs, panes, layouts, themes, plugins,
configuration, updates, resurrection data, and process behavior.

## Rust source builds

### Sidebar and settings

The Rust development build for Linux and Windows shows tmux, Zellij, and
Herdr TUI sessions in one list per host. The host’s **+** stays visible: use it
to create a session or **Add Project…**. Right-click a session or select its
**⋯** button for session actions. That button sits after the backend label,
appears on hover, and stays visible on the active row. Click the host name
or its arrow to collapse or expand its sessions and projects. The open
terminal stays attached, and **+** remains available while collapsed.

![A collapsed local host with its terminal still open in the Rust application](/docs/assets/guide-rust-collapsed-host.png)

Right-click a host and choose **Refresh** to reread its inventory. **Connect**,
**Cancel**, and **Retry** stay visible in the header when needed.

Open the three-line **Sidebar options** button beside **Workspaces** and
choose **Manual**, **Name**, **Backend**, or **Needs Attention** to sort the
list. The icon gains a filled circle when a sort is active. In Manual mode,
drag sessions into your preferred order, including across backends on the
same host.
Stopped Herdr sessions stay at the bottom.
With a session open, **Ctrl-Tab** and **Ctrl-Shift-Tab** follow the displayed
session order and skip stopped sessions.
From a worktree hidden from the session list, these shortcuts open the first
or last available session on the same host. If there is no destination,
the terminal receives the shortcut.

![The Rust sidebar with tmux, Zellij, and Herdr TUI sessions on Linux](/docs/assets/guide-rust-sidebar.png)

The options menu also offers **Backend Label** (Chip, Text, or Dot), **Row
Height** (Regular or Compact), **Hide Worktree Sessions**, and **Hide Root
Checkout**. Choose **Sidebar Settings…** for a live preview of these choices.
Changes save immediately and apply to every open window. You can also reach
these settings through the gear button, then **Sidebar**.

![Sidebar settings and the live preview in the Rust application on Linux](/docs/assets/guide-rust-sidebar-settings.png)

Herdr desktop terminals, hidden-worktree filtering, and worktree diff/PR/check
indicators are still being added to the Rust port.

### Live agent badges

Tmux sessions show **Approval**, **Input**, or **Working** when KWT agent hooks
are installed on their host. Hover the row to see the agent name. These badges
work on the local Linux/WSL default server and on the default and `kwt` servers
of SSH hosts, including SSH connections from native Windows. Registered
worktree and directory rows on those servers show the same state.

Choose **Needs Attention** from Sidebar options or **Settings → Sidebar** to
put approval and input requests first, then working agents. Equal-priority
sessions keep their manual order. Stopped Herdr sessions stay at the bottom,
and sibling shortcuts follow the displayed order.

![The Rust sidebar with live agent requests and Needs Attention sorting](/docs/assets/guide-rust-agent-attention.png)

Set up hooks on each host where agents run:

1. Open **Settings → Hosts** and select **Local** or a saved SSH host. On
   Windows, select the WSL host for local agents, or the SSH host where they run.
2. Connect an SSH host if needed. **Agent Hooks** lists detected agents and
   shows **Not installed**, **Update available**, or **Installed**.
3. Choose **Install Hooks** to edit those agents' user settings on that host.
   Ghosthub uses its pinned KWT helper and keeps hooks owned by other tools.
4. In Codex, open `/hooks` once to trust the new hooks. Choose **Reload** to
   read the status again after changing settings outside Ghosthub.

![Agent hook status and Install Hooks in the Rust app's host settings](/docs/assets/guide-rust-agent-hooks.png)

Setup errors stay in this panel. Correct the agent settings or SSH connection
and choose **Reload** before trying again. Closing the window or reconnecting
an SSH host cancels a pending setup request. Hooks already installed stay in the
agent's settings.

Agents can use the same setup from a shell on that host with KWT installed:

```sh
kwt agent-hook status --json
kwt agent-hook install --json
```

Ghosthub reads the pane state without reading terminal text. Badges refresh
about every ten seconds while Ghosthub is in front, or when you choose
**Refresh** from the host menu. An agent that does not send hooks has no badge.
A failed hook read does not prevent opening sessions.

Completed-turn acknowledgements and **Done** badges are not yet available in
the Rust app. Protected worktree servers, Herdr, and Zellij do not yet show
agent badges.

### Hide tmux sessions by name

Open **Settings → Worktrees** and enter one pattern per line under
**Hidden session patterns**. Matching is case-sensitive and covers the whole
name: `scratch-*` hides names starting with `scratch-`, and `build-?` matches
`build-1` but not `build-12`. `*` matches any number of characters; `?` matches
one character.

Edits save immediately and apply to local and SSH hosts. Matching tmux rows
leave the sidebar and **Ctrl-Tab** navigation. Running terminals stay attached,
project worktrees remain visible, and Herdr and Zellij rows are unaffected.
Choose **Clear patterns** to restore the rows. The patterns survive restarting
Ghosthub; configuration users can edit `[sidebar].hidden-session-patterns`.

![Worktrees settings filter tmux session rows while leaving the current terminal attached](/docs/assets/guide-rust-session-patterns.png)

### Session controls

Right-click a session or select its **⋯** button. The available actions depend
on the backend and whether the session is running:

| Action | Result |
| --- | --- |
| **Detach** | Closes the active terminal presentation and leaves the session running. Closing the terminal has the same effect. |
| **Rename Session…** (standalone tmux) | Changes the name and keeps its clients attached in every window. |
| **Kill Session…** (tmux or Zellij) | Asks for confirmation, then ends the session and its programs. |
| **Stop Session…** (running Herdr) | Asks for confirmation, then ends every process while keeping the saved workspace layout. |
| **Restart** (stopped Herdr) | Reopens the saved layout with new processes. Clicking the stopped row also restarts it. |
| **Delete Session…** (stopped, named Herdr) | Asks for confirmation, then removes the session and its saved layout. Herdr’s default session cannot be deleted. |

![The Rust session menu offers Restart and Delete for a stopped Herdr session](/docs/assets/guide-rust-session-actions.png)

To rename a standalone tmux session, choose **Rename Session…**, edit the
selected name, then press **Enter** or choose **Rename**. **Cancel** or
**Escape** leaves the name unchanged. The new name must be unique on that
host, use 1–100 characters, and exclude `#`, periods, colons, and control
characters. KWT-owned worktree and directory sessions keep their assigned
names; names starting with `kwt-wt-` or `kwt-workspace-` are reserved.
Rename is available after KWT discovery finishes successfully or confirms
that KWT is not installed. If discovery fails, refresh the host first.
Developer builds without the bundled KWT helper cannot check ownership and
do not offer Rename; use a build with the helper included.
Renaming supports local Linux/WSL sessions and connected POSIX SSH hosts.
Manual sidebar order follows the renamed session.

![Rename a standalone tmux session in the Rust application](/docs/assets/guide-rust-session-rename.png)

Destructive controls apply to local Linux and connected SSH sessions. Success
closes matching clients across windows; cancellation preserves the session. A
same-name tmux replacement requires a new confirmation. A failed kill restores
a still-active session only where navigation is unchanged.
Zellij cannot distinguish an otherwise identical same-name replacement, and
exited sessions stay hidden. See the [native Linux development guide](https://github.com/kenn-io/ghosthub/blob/main/docs/rust-port.md#native-linux-ssh-sessions)
for build instructions and native session controls. The Rust port supports
Zellij 0.45.1. Names beginning with `-` (except `-` itself), `help`, and `options`
cannot be created or attached; existing sessions remain visible and killable.

![Confirm a remote tmux kill in the native Rust application](https://github.com/user-attachments/assets/11938b82-22ae-4f84-b653-d9edcfc03592)

![Confirm Stop for a running Herdr session on the SSH host](https://github.com/user-attachments/assets/2a5220ee-c9d6-4b6b-a227-975578bf0f89)

![Confirm Delete for the stopped remote Herdr session](https://github.com/user-attachments/assets/a4185835-f0e8-4a75-a7f0-6318a4eaecdf)

![Confirm a remote Zellij kill in the native Rust application](/docs/assets/guide-rust-remote-zellij-kill.png)
