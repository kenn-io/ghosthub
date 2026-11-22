---
description: Create, attach, preview, rename, restore, and end tmux, Herdr, Rex, and Zellij sessions.
icon: lucide/square-terminal
---

# Sessions

Attach to a running session, start a new one, or jump into work kicked off by a
shell or coding agent without opening a local shell. Closing a Ghosthub window
or tab leaves your session running.

Expand any host in the sidebar to see its sessions, followed by a **Projects**
group:

- The session list shows every session on that host that is not grouped under a
  project. A label at the end of each row identifies its backend:

  | Label | Session |
  | --- | --- |
  | **tmux** | tmux session |
  | **zellij** | active Zellij session |
  | **herdr** | live Herdr desktop tab or terminal (macOS) |
  | **herdr tui** | running or stopped session from the older Herdr terminal app |
  | **rex** | window on a running Rex server (macOS and Linux) |

- **Projects** lists Git worktrees and registered directories backed by tmux
  sessions.

If Herdr, Rex, or Zellij is not installed on a host, nothing extra shows up. You
can run several multiplexers side by side on the same machine, and each keeps
its own panes, layout, scrollback, key bindings, and running programs. To change
backend labels or list sorting, see
[Arrange the session list](#arrange-the-session-list).

![Ghosthub showing tmux, Herdr, and Zellij sessions in one labeled list, with an active Zellij session and its Command Palette actions](/docs/assets/guide-sessions.png)

## Sessions started by tools and agents

Ghosthub and your command-line tools share the exact same sessions. If a shell
script or coding agent starts an ordinary tmux, Herdr, or Zellij session on any
configured host, it shows up in Ghosthub's sidebar with no special wrapper
command. Herdr and Zellij sessions started outside Ghosthub appear within about
30 seconds while Ghosthub is active and the host is connected.

For example, create a detached tmux session on your Mac or an SSH host:

```sh
tmux new-session -d -s agent-review
```

Click **agent-review** in that host's session list. You and the agent are now
looking at the same live session, and closing Ghosthub leaves it running.

For project work, agents can run `kwt list --json` inside a repository to list
its worktrees and their exact tmux session names. Kwt-managed sessions run on
kwt's tmux server, described next. Ghosthub's manual worktree flags are
reminders stored on your Mac; they do not report agent progress.

## Find tmux sessions on kwt's server

Ghosthub reads both the default tmux server and kwt's tmux server. Sessions tied
to a registered worktree or directory appear under **Projects**. Everything else
on either server appears in the host's session list, including sessions started
with `kwt tmux run`. Ghosthub attaches on whichever server owns the session. It
does not scan arbitrary custom tmux servers.

Use tmux's normal window chooser (usually your prefix key then `w`) to switch
windows inside a session. To list sessions on kwt's server from a shell:

```sh
env -u TMUX_TMPDIR tmux -L kwt list-sessions
```

Kwt always uses its own socket directory even if your shell sets `TMUX_TMPDIR`,
and Ghosthub's macOS app matches that rule. The default tmux server keeps using
your shell's socket directory.

If Ghosthub cannot reach kwt's server, it shows a warning next to the host.
Default-server sessions still refresh normally, and kwt rows keep their last
known state until discovery succeeds again.

## Create a standalone session

1. Click the **+** at the right end of the host's row in the sidebar.
2. Choose **New tmux Session…**, **New Zellij Session…**, or **New Herdr
   Session…**.
3. Enter a session name.

Backends that are not installed on that host stay in the menu, dimmed. Hover
over one to see why it is unavailable.

A new tmux session is a normal tmux session you can also reach from the `tmux`
CLI. To start a remote tmux session with a saved command, use a
[launch profile](launch-profiles.md).

A new Herdr session launches through Herdr itself and attaches immediately. The
create action is enabled when a supported Herdr CLI (0.8.0+) is available on
that host. Ghosthub rejects a Herdr TUI name that already exists in running or
stopped state; restart the stopped session instead.

A new Zellij session uses Zellij's normal new-session path. Ghosthub rejects
names that match an active or exited resurrectable session, because Ghosthub
only lists active Zellij sessions and does not resurrect exited ones.

## Herdr desktop terminals

Ghosthub on macOS can open live terminals from the newer
[Herdr desktop app](https://github.com/herdrdev/herdr-app). This connects
through [herdr-core](https://github.com/herdrdev/herdr-core), which tracks
terminals separately from older Herdr TUI sessions. Windows and Linux builds do
not support Herdr desktop yet.

A Herdr desktop tab opens with all of its terminal panes in the
[split layout](#herdr-desktop-splits) Herdr desktop maintains. A standalone
terminal that is not part of a tab, such as one started with `herdr-core run`,
opens on its own.

1. Install `herdr-core` on the Mac or SSH host where the terminal runs, and make
   sure it is on that account's login-shell `PATH`. The upstream installer puts
   it in `~/.local/bin`; `hc` is an optional alias.
2. Open a terminal in Herdr desktop, or run `herdr-core run --bg --name review`.
3. Click the tab's or terminal's **herdr** row in the host's session list, or
   press ++shift+cmd+p++ and search for its name or address. A tab row shows the
   tab name followed by its desktop space and pane count; a standalone terminal
   row shows its name followed by its address, such as `t7`.

![A Herdr desktop terminal and an older Herdr TUI session in one host's session list.](/docs/assets/guide-herdr-core.png)

Switching away or pressing ++cmd+w++ detaches and leaves the programs running.
When a program exits, Ghosthub removes its pane, and closes the view once the
last pane ends. Press ++ctrl+tab++ or ++ctrl+shift+tab++ to step through the
host's session list. Herdr desktop's own space, tab, and pane shortcuts stay in
Herdr's window.

Create new terminals in Herdr desktop or with its CLI. Ghosthub's **New Herdr
Session…**, **Stop Session…**, **Restart**, and **Delete Session…** actions are
for the older Herdr TUI app only.

Ghosthub checks the default `herdr-core` instance on each host. It skips
finished terminals and terminals forwarded through core's own remote-machine
links; add those machines as Ghosthub SSH hosts instead. Custom `HC_SESSION`
instances and `HC_SOCKET` overrides are ignored. Just like running the CLI by
hand, `herdr-core ls` can start the default core if it is not running yet.

Agents work with the same terminals using `herdr-core ls --json`,
`herdr-core read t7`, and other `herdr-core` commands. Ghosthub tracks each
terminal by its address, so renaming a terminal does not break attachment.
Agents can inspect the desktop layout with `herdr-app ls`, which uses the same
addresses. Desktop tabs are tested with `herdr-core` 0.1.21.

### Herdr desktop splits

A Herdr desktop tab's terminal panes appear side by side in the same layout as
Herdr desktop and stay in sync as it changes: splitting, closing, or resizing a
pane in Herdr updates Ghosthub within moments, and closing the tab in Herdr
closes it in Ghosthub. Each pane header shows its terminal's name.

Herdr desktop owns the layout, and Ghosthub displays it read-only. Click a pane
or use the pane-focus shortcuts to choose where you type, and zoom any pane to
fill the window; focus and zoom stay local to Ghosthub. To split, close, resize,
or move panes, make the change in Herdr desktop. Ghosthub's **Split Right**,
**Split Down**, and **Close Pane** actions are disabled for desktop tabs. A
stacked pane shows its front terminal, and non-terminal Herdr panels and edge
drawers are hidden.

Older Herdr TUI sessions open as a single whole-session view, including any
splits inside them.

## Rex windows

### macOS

Ghosthub on macOS opens windows from a running
[Rex](https://www.superlogical.com/rex/docs) server on your Mac or an SSH host,
complete with their split panes.

1. Install Rex Server and start it, for example by opening Rex. Ghosthub never
   starts a stopped Rex server.
2. Open a window in Rex, or run `rex run -- htop`.
3. Expand the host in Ghosthub and click the window's **rex** row, or press
   ++shift+cmd+p++ and search for it. Each row shows the window name (or its
   focused pane's name, such as `zsh ~`) followed by its Rex session and pane
   count.

Click any pane to focus it. While a pane is focused:

| Action | Shortcut |
| --- | --- |
| Split right | ++cmd+d++ |
| Split down | ++shift+cmd+d++ |
| Focus the pane to the left, right, above, or below | ++option+cmd+left++, ++option+cmd+right++, ++option+cmd+up++, ++option+cmd+down++ |
| Focus the next or previous pane | <kbd>⌘</kbd><kbd>&#93;</kbd>, <kbd>⌘</kbd><kbd>&#91;</kbd> |
| Zoom or unzoom the pane | ++shift+cmd+enter++ |

Drag the divider between panes to resize them. To move a pane, drag its header
onto another pane: drop it on any half of the target pane to place it there, or
on the center to swap the two panes. Press ++escape++ to cancel a drag. The
focused pane's header also has split, zoom, and close buttons. **Close Pane…**
in the header or Command Palette asks for confirmation first because it ends
that pane's program. Every layout change goes through Rex, so Rex.app and other
clients stay in sync both ways.

Rex also supports floating panes over the split layout:

- **New Floating Pane** in the Command Palette opens a shell in a floating
  window in the focused pane's working directory.
- **Float Pane** in a pane header pops that pane into a floating window. On a
  floating pane, **Tile Pane** puts it back into the split layout.
- Drag a floating pane's header to move it, or drag an edge to resize it. Click
  a pane to bring it to the front.
- **Minimize** shrinks the floating window to a button in the lower-right
  corner; click the button to bring it back.

Floating commands have no default shortcuts; assign your own in
**Settings → Keyboard**.

Switching away or pressing ++cmd+w++ detaches and leaves every pane running.
Press ++ctrl+tab++ or ++ctrl+shift+tab++ to move to the next or previous session
on the host. Closing the window in Rex closes it in Ghosthub. If a single pane
loses its connection, Ghosthub reattaches it automatically or shows **Reconnect**
on that pane.

Ghosthub talks to Rex through its bundled kwt, so you do not need any extra
local client. On SSH hosts, it uses the
[managed kwt helper](remote-hosts.md#managed-kwt-helper).

### Linux: remote Rex windows

The Linux client opens Rex windows on macOS and Linux SSH hosts, showing their
tiled terminal panes. Rex owns the layout and running programs; changes made in
Rex appear in Ghosthub, and Ghosthub's pane controls send changes back to Rex.

1. [Install and start Rex Server](https://www.superlogical.com/rex/docs/linux/installation)
   on the remote machine under your SSH account, and create a Rex session such
   as `rex new Work`. Ghosthub does not install Rex or start a stopped server.
2. Add the machine in **Settings → Hosts**. For a Tailscale peer, enter its
   MagicDNS hostname and remote username, and make sure SSH connects first.
3. Connect the host and pick its **rex** row in the sidebar or Command Palette.
   Ghosthub installs the matching managed kwt helper automatically.

![A remote Rex window with tiled terminal panes in the Linux client](/docs/assets/guide-rust-rex.png)

Click a pane or its header to focus it. The focused pane's header has buttons
for **Split Right**, **Split Down**, **Zoom Pane**, and **Close Pane…**, all
also in the Command Palette. Drag a divider and release to resize; Rex confirms
the new layout before the terminal grids resize. New splits open in the remote
shell's default directory.

| Shortcut | Action inside a Rex window |
| --- | --- |
| ++ctrl+shift+d++ | Split Right |
| ++ctrl+shift+e++ | Split Down |
| ++ctrl+alt+left++ / ++ctrl+alt+right++ / ++ctrl+alt+up++ / ++ctrl+alt+down++ | Focus a neighboring pane |
| ++ctrl+bracket-left++ / ++ctrl+bracket-right++ | Previous / next pane |
| ++ctrl+shift+enter++ | Toggle pane zoom |

These shortcuts apply inside Rex windows only. Your saved Ghosthub shortcuts
take priority, and normal terminal shortcuts keep working in tmux, Herdr, and
Zellij.

**Close Pane…** asks before ending that pane's program. To detach while leaving
everything running, choose **Detach** in the window row's menu or switch to
another session. Selecting the Rex window again reattaches to its live panes.

If one pane disconnects, click **Reconnect** on that pane. If the whole window
loses SSH, reconnect the host if needed and click the window or its
**Reconnect** button. Local Rex discovery and non-tiled Rex layers are not
supported on Linux yet.

## Attach and detach

Click any running tmux, Herdr, or Zellij session in the sidebar, or press
++shift+cmd+p++ to search for it in the Command Palette. Ghosthub attaches using
the backend's normal local or SSH client. Herdr TUI takes the full terminal and
keeps control of its workspaces, tabs, panes, history, and key bindings. Herdr
desktop tabs and standalone terminals attach as described under
[Herdr desktop terminals](#herdr-desktop-terminals).

On macOS, selecting an existing Zellij 0.45 session attaches directly instead of
opening Zellij's session picker. Session names starting with `-` (other than `-`
by itself), `help`, or `options` cannot be created or attached because Zellij
parses them as flags or subcommands; existing sessions with those names still
appear in the sidebar and can be killed after confirmation.

For macOS and Linux tmux sessions, Ghosthub turns on tmux mouse mode when it
attaches so wheel scrolling enters and scrolls tmux copy mode even with a
default tmux config. Mouse mode is a session-wide tmux option, so other clients
attached to that session see it too, while tmux's own mouse bindings stay in
charge. Native Windows hosts running psmux keep psmux's mouse-reporting limits.

Switching to another host, worktree, or session hides an open tmux view without
detaching it. Each Ghosthub window keeps the tmux sessions you opened connected,
so switching back is instant and reuses the same client. Switching away from
Herdr or Zellij detaches that view while leaving the server and your programs
running.

Zellij has no atomic command that attaches only if a session is still active.
Ghosthub verifies that a Zellij session is active right before attaching and
never offers resurrection, though Zellij itself can resurrect a saved layout if
the session happens to exit in the brief moment before the attach command runs.
Ghosthub does not ask Zellij to rerun resurrected commands automatically.

Press ++cmd+w++ to detach only the active session view. Closing a Ghosthub tab
or window detaches every session open in that tab or window, and quitting
Ghosthub detaches all of them. None of those actions kills a tmux session or
stops a Herdr or Zellij server. After a normal Herdr or Zellij detach, Ghosthub
shows a **Reconnect** button and does not retry on its own.

## Recover a connection

When an SSH connection drops, Ghosthub starts retrying automatically and checks
for the exact same session before attaching a new client. Retries stop if the
session disappears, Herdr is no longer available, or the client fails for a
reason other than a dropped connection. Click **Reconnect Now** to skip the wait
timer; host-key or login issues open the connection review sheet. See
[Automatic reconnect](remote-hosts.md#automatic-reconnect) for controls and
error messages.

After relaunching Ghosthub, a remote Zellij session restores only if the host's
SSH route still matches. If you edit the host's SSH settings mid-check, restore
stops rather than connecting to a different machine.

If your Mac wakes without an active display, Ghosthub waits instead of treating
the missing display as a permanent failure. Reconnect resumes once a display is
available, without rerunning any saved tmux launch-profile command.

## Paste text or images and open links

Press **Command-V** to paste text or images. See
[Clipboard behavior](terminal-configuration.md#clipboard-behavior) for how image
pasting, text priority, and cleanup work. **Control-V** passes straight through
to the program inside the terminal.

Hold **Command** and click any highlighted link to open it in your default macOS
app.

## Find text in a terminal

Press **Command-F** or run **Find in Terminal** from the Command Palette. Find
searches the active pane's full scrollback in standalone terminals and in macOS
or Linux tmux 3.4+ sessions. Herdr, Zellij, Windows/psmux, and older tmux
versions do not support Find.

Press **Return** or **Command-G** to jump to older matches, and
**Shift-Return** or **Shift-Command-G** for newer matches. Press **Escape**,
**Shift-Command-F**, or the close button to exit Find.

Standalone terminal search stops at the ends without wrapping. Inside tmux, tmux
controls wrapping and search direction, and because copy mode is shared on the
pane, another client attached to the same pane can see or cancel the search.

![Find bar searching an active tmux pane's history](/docs/assets/guide-find.png)

## Preview opened tmux sessions

Open **Settings → Terminal → Session previews**, choose **Efficient**, **Live**,
or **Always Live**, and click **Done**.

With **Efficient** or **Live**, each tmux session you have opened in that window
gets a disclosure toggle in the sidebar; expand it to preview the terminal. With
**Always Live**, Ghosthub connects to every newly discovered tmux session on
reachable macOS and Linux hosts and expands its preview automatically. Every
preview tile matches its terminal's aspect ratio without cropping. Clicking a
preview switches to that session just like clicking its row.

![Ghosthub sidebar showing Always Live previews expanded for discovered tmux sessions](/docs/assets/guide-session-previews.png)

Each mode trades resource use for freshness:

- **Off** (default) hides preview toggles, clears cached frames, and uses no
  preview GPU time.
- **Efficient** updates a preview when you expand it and when you switch away
  from that session. It does not refresh in the background.
- **Live** refreshes expanded previews at up to 2 frames per second. Across the
  whole app, up to four inactive tmux sessions can render live at once; any
  extra expanded tile notes that the live-preview limit is reached.
- **Always Live** automatically attaches to every newly discovered tmux session
  on reachable macOS and Linux hosts, expands its tile, and refreshes all
  expanded tiles with no four-session cap. This uses noticeably more CPU, GPU,
  memory, and SSH connections. Collapse any tile to pause its rendering while
  keeping its client connected. Ghosthub attaches clients gradually so early
  tiles show up while larger sets of sessions are still connecting.

Which tiles you expand stays in memory per window (even if you toggle previews
Off and back on) and resets when that window closes. Hiding the sidebar or
switching away from Ghosthub pauses live rendering until the sidebar is visible
and Ghosthub is active again; **Always Live** keeps its background clients
connected during that pause.

**Efficient** and **Live** only preview sessions you already opened. **Always
Live** opens an extra tmux client for each discovered session on macOS and Linux
hosts. Switching away from **Always Live** detaches only the clients it opened
automatically, while clicking a preview lets you interact with that same client.

Previews require tmux 3.4 or newer. If a host runs an older version or setup
fails, **Always Live** skips automatic attachment and you can still open the
session normally. Native Windows/psmux sessions are never attached
automatically. Preview tiles never resize the underlying tmux window.

While a session is reconnecting, a placeholder replaces the old frame until
Ghosthub confirms it reattached to the exact same session. Detaching the client
or finding a different session reusing the same name clears its preview.

## Activity indicators

Once you connect to a session, Ghosthub remembers it for the rest of that app
run. A small accent dot appears beside its standalone or worktree row whenever
new output scrolls into its tmux scrollback, then clears about 30 seconds after
output stops.

![Ghosthub sidebar showing an accent activity indicator beside a standalone session that is producing output while another session is selected](/docs/assets/guide-session-activity.png)

Only real output triggers the dot. Switching panes, resizing a window, or a
full-screen app redrawing its prompt, spinner, or status bar does not set it
off. Closing a window only detaches, so the activity dot stays visible in your
other Ghosthub windows.

Activity tracking resets when you quit Ghosthub. Ghosthub never probes sessions
you have not opened, and terminal text never leaves the host: the check returns
only a checksum and size counters. On native Windows hosts, activity dots
require psmux 3.3.4 or newer.

## Agents waiting for you

A tmux session running a coding agent shows a status badge at the right edge of
its sidebar row:

- **Approval** (amber bubble): the agent is waiting for permission.
- **Input** (purple bubble): the agent asked a question.
- **Done** (green dot): the agent finished a turn you have not seen yet.
- **Working** (pulsing green dot): the agent is busy.

The native tab holding that session shows the same icon beside its shortcut.
Hover over a badge to see which agent reported it.

![Ghosthub sidebar with Approval, Input, Done, and Working badges on four tmux sessions](/docs/assets/guide-agent-attention.png)

**Done** clears as soon as you view that session in the front window.
**Approval** and **Input** stay visible until the agent continues.

To enable agent badges on a host:

1. Open **Settings → Hosts** and select your Mac or a remote host.
2. Under **Agent Hooks**, click **Install Hooks**.
3. In Codex, run `/hooks` once to trust the new hooks.

Ghosthub installs hooks for each supported agent already set up on that host,
including Claude Code, Codex, Antigravity CLI (`agy`), Gemini CLI, and Cursor.
`agy` reports **Working** and **Done** only. Badges refresh when you switch to
Ghosthub and roughly every 30 seconds while it stays in front. Native Windows
hosts and Herdr and Zellij sessions do not show agent badges yet.

## Restore sessions after a reboot

kwt saves your tmux sessions as they change, recording each session's windows,
panes, working directories, and any Claude Code, Codex, or Antigravity CLI
(`agy`) conversation running inside them. After a host reboots or its tmux
server stops, those saved sessions appear in the host's session list as dimmed
**saved** rows below the running sessions.

![Sidebar listing two saved tmux sessions as dimmed rows below the running sessions](/docs/assets/guide-session-restore.png)

- Click a saved row to restore that session and attach to it. The row shows
  **restoring…** while agents start, which can take a few seconds.
- To restore every saved session on a host at once, open the host's **+** menu
  or the Command Palette and choose **Restore Saved tmux Sessions**.
- To discard a saved session without restoring it, open its **⋯** menu, choose
  **Dismiss Saved Session…**, and confirm. kwt deletes the saved layout and
  conversation references.

Ghosthub rebuilds each session's windows and panes in their saved directories
and resumes each saved agent conversation in its pane. Panes without a saved
agent come back as normal shells. If any session or pane fails to restore,
Ghosthub tells you why, such as a session name already in use or a conversation
kwt could not find.

Saved worktree and directory sessions do not get separate **saved** rows. Click
the workspace row as usual, and kwt restores its saved session when opening it.

- Conversations resume only in panes where kwt's agent hooks recorded them. See
  [Agents waiting for you](#agents-waiting-for-you) to install the hooks.
- Codex running on its shared background daemon comes back as a plain shell
  because its hooks cannot tell kwt which pane it ran in. Start Codex with
  `codex --no-daemon` to keep its conversation restorable.
- A session you end with **Kill Session…** is forgotten and will not be offered
  for restore later.
- Session restore covers the default tmux server and kwt's server on your Mac
  and on macOS and Linux SSH hosts. Native Windows hosts do not save sessions.

## Reopen an exited standalone session

If a standalone tmux session exits while its view is still open, Ghosthub shows
a **Reopen** button. Clicking it starts a fresh tmux session with the same name;
it cannot bring back the exited processes.

If you detached cleanly or confirmed a kill, the view stays closed until you
open or reopen it yourself.

## Rename a standalone session

Open a standalone tmux row's **⋯** menu (or Control-click the row) and choose
**Rename Session…**, or run **Rename tmux session** in the Command Palette. The
new name must be unique on that host and cannot include periods, colons, or line
breaks. Open views stay connected across every Ghosthub window and keep all
their windows, panes, and running programs. If the session is still connecting
in the window you rename from, wait a moment and try again.

![Rename tmux session sheet with the current session name ready to edit](/docs/assets/guide-session-rename.png)

Kwt-managed worktree and directory sessions keep the names kwt assigns and
cannot be renamed. For the same reason, custom names cannot start with `kwt-wt-`
or `kwt-workspace-`. Renaming is not available on native Windows hosts.

## End a session deliberately

Every session row shows a **⋯** menu right after its backend label when you
hover over it or select it. To end a standalone tmux or active Zellij session,
open that menu (or Control-click the row) and choose **Kill Session…**. For a
kwt worktree or directory session, open the workspace row's **…** menu and
choose **Kill Session…**.

Ghosthub asks you to confirm the exact host and tmux session before sending
`kill-session`. Killing a session ends all of its windows, panes, and programs
and cannot be undone.

For tmux, Ghosthub aborts the kill if the host connection changes or if the
original session disappears and a different session appears with the same name.
If the kill fails, your open view stays attached.

Herdr TUI sessions are controlled as whole sessions:

- A running row offers **Stop Session…**. Confirming ends every shell, agent,
  server, and process inside it while keeping Herdr's saved workspace, tab, and
  pane layout.
- A dimmed **stopped** row offers **Restart**, which starts new processes in
  that saved layout and attaches immediately.
- A stopped named row also offers **Delete Session…**, which permanently removes
  its saved state after confirmation.
- Herdr's default session can be stopped and restarted, never deleted.

All of these actions are also in the Command Palette. While a confirmed stop is
running, Ghosthub pauses reconnects in every open window so another window does
not silently bring the session back.

An active Zellij row offers **Kill Session…**. Ghosthub confirms the host and
session name, verifies that the session is still active right before sending the
command, and asks Zellij to kill it. While the kill runs, Ghosthub detaches that
session and pauses reconnects to it across every open window so an existing
client or automatic reconnect cannot undo the kill. When the kill succeeds,
Ghosthub removes the row everywhere and refreshes Zellij inventory. If the kill
fails, Ghosthub rechecks the session before allowing any detached view or
pending open to resume. Because Zellij does not provide a tmux-style stable
session ID, a brand-new session created with the exact same name between the
final check and the kill command is an accepted race. Ghosthub never resurrects
or deletes exited Zellij sessions.

!!! warning "Killing a session is different from removing a worktree"

    **Kill Session…** stops the tmux session and its programs while leaving the
    Git checkout on disk. Removing a worktree stops its verified live tmux
    session if needed and removes the checkout, while keeping the Git branch.
    See [Remove a worktree](projects-worktrees.md#remove-a-worktree).

## Arrange the session list

Click the options menu (the stacked lines beside **Workspaces** at the top of
the sidebar) to pick how every host's session list is ordered:

- **Manual** keeps the order you set by dragging rows. You can drag any session
  onto another row on the same host, including across backends. Sessions you
  have not arranged yet appear after placed ones, grouped by backend.
- **Name** sorts alphabetically.
- **Backend** groups tmux, Zellij, Herdr desktop, and Herdr TUI sessions, sorted
  by name within each group.
- **Needs Attention** puts sessions waiting for agent approval or input at the
  top, followed by working agents, then finished turns. Other sessions keep
  their manual order.

Stopped Herdr sessions always stay at the bottom. ++ctrl+tab++ and
++ctrl+shift+tab++ walk the list in the same displayed order. Whenever a sort
other than **Manual** is active, the options icon highlights in the accent
color.

The same menu toggles the other sidebar options right away:

- **Backend Label**: **Chip** (default), colored **Text**, or a colored **Dot**
  before the name.
- **Row Height**: **Regular** or **Compact**.
- **Hide Worktree Sessions**, **Hide Root Checkout**, and **Show Hidden
  Worktrees**.

To preview changes before applying them, choose **Sidebar Settings…** from the
menu or open **Settings → Sidebar**. A sample sidebar at the top updates as you
pick options; click **Done** to apply them.

## Hide standalone sessions

To keep background or noisy standalone tmux sessions out of the sidebar:

1. Open **Settings → Worktrees**.
2. Add hidden tmux session patterns, one per line.

Patterns are case-sensitive. `*` matches any number of characters and `?`
matches a single character. Ghosthub saves these patterns in
`~/.config/ghosthub/config.toml`.

Patterns hide standalone tmux sessions only; matching kwt worktrees stay visible
under their project.

Kwt-managed tmux sessions are also hidden from the host's standalone session
list by default so they do not appear twice. To show those duplicate rows, turn
off **Hide Worktree Sessions** in the sidebar options menu. Either way, the
worktree row's status indicator reflects the live tmux session.

## Ownership and safety

Closing a Ghosthub view never ends your work. Ghosthub kills a tmux session only
when you confirm **Kill Session…** or confirm removing a worktree that has a
verified live session. Sessions started outside Ghosthub get the exact same
protection as sessions started inside it.

For Herdr TUI, Ghosthub handles only whole-session create, stop, restart, and
delete, plus explicit **Split Right** and **Split Down** requests on a connected
Herdr 0.8.0+ session. Herdr chooses the focused pane and owns themes,
workspaces, tabs, panes, agents, plugins, config, updates, and processes.

For Zellij, Ghosthub handles only active-session create, attach, and confirmed
kill. Zellij owns tabs, panes, layouts, themes, plugins, config, updates,
resurrection data, and processes.

## Rust source builds

### Sidebar and settings

The Rust development build for Linux and Windows lists tmux, Zellij, and Herdr
TUI sessions in one list per host. Each host's **+** button stays visible for
creating a session or choosing **Add Project…**. Right-click a session or click
its **⋯** button (shown on hover and on the selected row, right after the
backend label) for session actions. Click a host name or its arrow to collapse
or expand its section; your open terminal stays attached and **+** stays
usable while collapsed.

![A collapsed local host with its terminal still open in the Rust application](/docs/assets/guide-rust-collapsed-host.png)

Right-click a host and choose **Refresh** to reload its inventory. **Connect**,
**Cancel**, and **Retry** appear in the host header when needed.

Click the three-line **Sidebar options** button beside **Workspaces** and choose
**Manual**, **Name**, **Backend**, or **Needs Attention** to sort the list. The
icon shows a filled dot when a sort is active. In **Manual** mode, drag sessions
into any order on the same host, including across backends. Stopped Herdr
sessions stay at the bottom. With a session open, **Ctrl-Tab** and
**Ctrl-Shift-Tab** walk the displayed order and skip stopped sessions. From a
worktree that is hidden from the session list, those shortcuts jump to the first
or last available session on the same host; if there is nowhere to jump, the
shortcut goes to the terminal.

![The Rust sidebar with tmux, Zellij, and Herdr TUI sessions on Linux](/docs/assets/guide-rust-sidebar.png)

The options menu also controls **Backend Label** (Chip, Text, or Dot), **Row
Height** (Regular or Compact), **Hide Worktree Sessions**, and **Hide Root
Checkout**. Choose **Sidebar Settings…** (or click the gear icon then
**Sidebar**) for a live preview. Changes save immediately and apply across every
open window.

![Sidebar settings and the live preview in the Rust application on Linux](/docs/assets/guide-rust-sidebar-settings.png)

Herdr desktop terminals, hidden-worktree filtering, and worktree diff/PR/check
indicators are still in progress for the Rust port.

### Live agent badges

Tmux sessions show **Approval**, **Input**, or **Working** when kwt agent hooks
are installed on their host. Hover over the row to see which agent reported it.
Badges work on the local Linux or WSL default server and on the default and
`kwt` servers of SSH hosts, including SSH connections from native Windows.
Registered worktree and directory rows on those servers show the same badges.

Choose **Needs Attention** from Sidebar options or **Settings → Sidebar** to
sort approval and input requests first, followed by working agents. Ties keep
their manual order, stopped Herdr sessions stay at the bottom, and **Ctrl-Tab**
follows the displayed order.

![The Rust sidebar with live agent requests and Needs Attention sorting](/docs/assets/guide-rust-agent-attention.png)

Install hooks on each host where agents run:

1. Open **Settings → Hosts** and select **Local** or a saved SSH host. On
   Windows, select the WSL host for local agents or the SSH host where they run.
2. Connect the SSH host if needed. **Agent Hooks** lists detected agents and
   marks each as **Not installed**, **Update available**, or **Installed**.
3. Click **Install Hooks** to update those agents' user settings on that host.
   Ghosthub uses its pinned kwt helper and leaves hooks owned by other tools
   alone.
4. In Codex, run `/hooks` once to trust the new hooks. Click **Reload** to
   recheck status after editing agent settings outside Ghosthub.

![Agent hook status and Install Hooks in the Rust app's host settings](/docs/assets/guide-rust-agent-hooks.png)

Setup errors stay inside this panel. Fix the agent config or SSH connection and
click **Reload** before trying again. Closing the window or reconnecting an SSH
host cancels an in-progress install while keeping any hooks already written.

Agents can run the same commands directly on any host with kwt installed:

```sh
kwt agent-hook status --json
kwt agent-hook install --json
```

Ghosthub reads pane state without reading terminal output. Badges refresh about
every 10 seconds while Ghosthub is in front, or when you choose **Refresh** in
the host menu. Agents without hooks show no badge, and a failed hook read never
blocks opening a session.

Completed-turn acknowledgements and **Done** badges are not in the Rust app yet.
Protected worktree servers, Herdr, and Zellij do not show agent badges yet.

### Hide tmux sessions by name

Open **Settings → Worktrees** and enter one pattern per line under **Hidden
session patterns**. Matching is case-sensitive and covers the full session name:
`scratch-*` matches names starting with `scratch-`, and `build-?` matches
`build-1` but not `build-12`. `*` matches any number of characters and `?`
matches one character.

Edits save immediately and apply to both local and SSH hosts. Matching tmux rows
disappear from the sidebar and **Ctrl-Tab** navigation while running views stay
attached, project worktrees stay visible, and Herdr and Zellij rows stay
untouched. Click **Clear patterns** to show them again. Patterns persist across
restarts; you can also edit `[sidebar].hidden-session-patterns` in the config
file.

![Worktrees settings filter tmux session rows while leaving the current terminal attached](/docs/assets/guide-rust-session-patterns.png)

### Session controls

Right-click a session or click its **⋯** button. Available actions depend on the
backend and whether the session is running:

| Action | Result |
| --- | --- |
| **Detach** | Closes the open view and leaves the session running. Closing the view has the same effect. |
| **Rename Session…** (standalone tmux) | Renames the session while keeping clients attached in every window. |
| **Kill Session…** (tmux or Zellij) | Asks for confirmation, then ends the session and its programs. |
| **Stop Session…** (running Herdr) | Asks for confirmation, then ends every process while keeping the saved layout. |
| **Restart** (stopped Herdr) | Starts new processes in the saved layout. Clicking the stopped row also restarts it. |
| **Delete Session…** (stopped, named Herdr) | Asks for confirmation, then removes the session and its saved layout. Herdr's default session cannot be deleted. |

![The Rust session menu offers Restart and Delete for a stopped Herdr session](/docs/assets/guide-rust-session-actions.png)

To rename a standalone tmux session, choose **Rename Session…**, edit the name,
and press **Enter** or click **Rename**. **Cancel** or **Escape** leaves the
name alone. The new name must be unique on that host, 1 to 100 characters long,
and free of `#`, periods, colons, and control characters. Kwt-owned worktree and
directory sessions keep their assigned names, and names starting with `kwt-wt-`
or `kwt-workspace-` are reserved.

Rename becomes available once kwt discovery finishes or confirms that kwt is not
installed; if discovery failed, refresh the host first. Developer builds without
the bundled kwt helper cannot verify ownership and do not show Rename. Renaming
works on local Linux/WSL sessions and connected POSIX SSH hosts, and manual
sidebar ordering follows the renamed session.

![Rename a standalone tmux session in the Rust application](/docs/assets/guide-rust-session-rename.png)

Confirmed kill, stop, and delete actions work on local Linux and connected SSH
sessions. When one succeeds, matching views close across all windows; cancelling
leaves the session untouched. If a tmux session is replaced by another session
with the same name, Ghosthub asks for a fresh confirmation. If a kill fails,
Ghosthub restores a still-active session only if you have not navigated away.

Zellij cannot tell a same-name replacement apart from the original session, and
exited sessions stay hidden. See the
[native Linux development guide](https://github.com/kenn-io/ghosthub/blob/main/docs/rust-port.md#native-linux-ssh-sessions)
for build instructions and session controls. The Rust port supports Zellij
0.45.1; names beginning with `-` (except `-` itself), `help`, and `options`
cannot be created or attached, though existing sessions with those names remain
visible and killable.

![Confirm a remote tmux kill in the native Rust application](https://github.com/user-attachments/assets/11938b82-22ae-4f84-b653-d9edcfc03592)

![Confirm Stop for a running Herdr session on the SSH host](https://github.com/user-attachments/assets/2a5220ee-c9d6-4b6b-a227-975578bf0f89)

![Confirm Delete for the stopped remote Herdr session](https://github.com/user-attachments/assets/a4185835-f0e8-4a75-a7f0-6318a4eaecdf)

![Confirm a remote Zellij kill in the native Rust application](/docs/assets/guide-rust-remote-zellij-kill.png)
