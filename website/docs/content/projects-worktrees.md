---
description: Register Git projects or plain directories and manage their worktrees and sessions.
icon: lucide/git-branch
---

# Projects, worktrees, and directories

Give each branch or pull request its own Git checkout and tmux session so you
and your coding agents can work on separate tasks without switching branches in
the same folder. Projects and worktrees are optional.

Ghosthub uses [kwt](https://kwt.sh) to track repositories and worktrees.
Packaged builds use a revision-pinned copy of kwt locally and keep a matching
managed copy updated on remote macOS and Linux hosts.

## Register a project

Start with an existing Git checkout on the host where the code lives.

1. Expand your Mac or a remote macOS or Linux host in the sidebar.
2. Click the **+** beside **Projects**.
3. Enter the checkout's full path on that host.
4. Confirm.

Ghosthub registers that single path with kwt and refreshes the sidebar. It never
scans the machine or edits kwt's config files on its own.

Bare repositories laid out as a `.bare/` folder with sibling worktrees work too.
Enter either the parent folder or any worktree path. New worktrees are created
beside the existing ones, and `.bare/` does not show up as a worktree row.

Ghosthub keeps the [managed kwt helper](remote-hosts.md#managed-kwt-helper) up
to date on configured macOS and Linux SSH hosts. Before any project or worktree
action, Ghosthub repairs the helper if needed; if repair still fails, that
action reports the error while your standalone sessions keep working. Adding
projects is not supported on native Windows hosts yet.

If you change a host's SSH destination while the Add Project sheet is open,
close the sheet and open it again so the registration targets the updated host.

## Find a moved project

If you move or rename a project folder, Ghosthub asks kwt to look for it among
the repositories kwt already knows about. If there is one clear match, Ghosthub
updates the project automatically. Ghosthub tries that automatic check once
while the project is missing, while normal refreshes still catch it if the
original folder comes back.

A missing project shows a folder question-mark button beside its name while your
other projects and sessions stay usable. Click that button, or Control-click the
project and choose **Locate Folder…**. On your Mac, click **Choose Folder…** or
type the new path; on a remote host, enter the path on that host. Pick the main
checkout of the same repository and click **Use Folder**.

![Locate Folder sheet for a moved project](/docs/assets/guide-project-recovery.png)

Ghosthub keeps the old registration until it verifies the new folder. Automatic
matching requires a repository identity, and if multiple clones match, you need
to choose one yourself. If the project has no stable repository identity, remove
its old registration and register the new path. You can also choose **Remove
Project…** if you no longer want it listed.

## Remove a project

Hover over a project row and click **×**, or Control-click the row and choose
**Remove Project…**, then confirm the project and host. Ghosthub unregisters the
project in kwt and refreshes the sidebar. You can unregister a project even if
its folder has already been deleted.

Removing a project never deletes your Git repository, worktree folders, or tmux
sessions. If an imported pull-request worktree still has a running session on
its protected tmux server, kill that session before removing the project. Any
ordinary tmux sessions that are still running stay available in the host's
session list.

![Ghosthub showing the Remove Project action and its non-destructive confirmation](/docs/assets/guide-project-removal.png)

If the project or host connection changes while the confirmation sheet is open,
Ghosthub stops and asks you to start again. Removing projects works on your Mac
and on macOS and Linux SSH hosts, not on native Windows hosts.

## Register a plain directory

A notes folder, monorepo hub, or any other non-Git directory can still use kwt
layouts and Ghosthub's session flow. Register it on the host where it lives:

```sh
kwt workspace add /absolute/path/to/directory
```

Refresh Ghosthub and the directory appears as a single flat row under
**Projects**, below your Git repositories. It has no expandable worktrees
because one registered directory maps to one workspace session.

Click the row to let kwt create or repair its layout and attach tmux. Removing
the directory later with `kwt workspace remove` leaves any live session running;
after a refresh, that session shows up in the host's session list.

## Open a project checkout

Click a project's main checkout or any linked worktree in the sidebar. kwt
supplies the exact tmux session name, Ghosthub creates or repairs the session if
needed, and then attaches tmux. The window title and native tab show the project
and worktree names instead of the internal session name. New worktree sessions
use kwt's short, hash-suffixed names; to list them from a shell, use the
[kwt-server command](sessions.md#find-tmux-sessions-on-kwts-server).

To open every visible worktree in a project inside one new window, right-click
the project and choose **Open All Worktrees as Tabs**. Ghosthub opens them in
sidebar order, creating or repairing each kwt session as needed. If one tab
cannot be created, Ghosthub stops there instead of scattering the rest into
separate windows.

Each worktree row shows how many tmux windows are open. While Ghosthub is
connected, that count refreshes with the background activity check: about every
5 seconds for a working session and every 20 seconds for a quiet one, including
protected sockets. Detached ordinary sessions use the count from discovery. When
no reliable count is available, the row falls back to a running or agent icon,
and cached sessions stop showing as live while a host is unreachable.

![Ghosthub showing a compact tmux window count on a worktree row](/docs/assets/guide-worktree-window-counts.png)

By default, a live kwt-managed session shows only on its worktree row so it is
not duplicated in the host's session list. To show both rows, turn off **Hide
Worktree Sessions** in the options menu beside **Workspaces** at the top of the
sidebar.

## Flag worktrees

Open the **…** menu beside a worktree (or Control-click the row) and choose
**Flag Worktree**. Its name turns amber and its icon becomes a filled flag.
Choose **Unflag Worktree** to clear it.

![Flagged primary and linked worktrees beside an unflagged checkout](/docs/assets/guide-worktree-flags.png)

Flags are manual reminders stored on your Mac. They show up in every Ghosthub
window and survive relaunches, even if the session stops or the host goes
offline. You can flag multiple worktrees, including the main checkout. Flagging
never opens a session, changes row order, or reacts to terminal activity.

Flagging turns on once discovery confirms a worktree's identity. A fresh
checkout created later at the same path starts unflagged.

## Inspect changed files

Click the disclosure arrow beside a worktree to expand its changed files without
selecting the worktree or attaching to its tmux session. You can leave multiple
worktrees expanded at once.

![Ghosthub showing staged, modified, and untracked files beneath a worktree](/docs/assets/guide-worktree-changes.png)

Each file shows staged and working-tree status separately when both apply, and
renamed files include their old path. A clean checkout shows **No changed
files**. Large lists show the first 200 files with a **Show more** button for
the rest. Expanded panels refresh about 5 seconds after each successful read.
Repeated temporary errors back off automatically, while permanent errors wait
until you click **Refresh**. Click **Refresh** for an immediate check, or click
the arrow to collapse the panel. If a refresh fails, Ghosthub keeps the last
good list visible and marks it stale.

If kwt reports that the worktree registration changed, automatic refreshes stop.
Click **Refresh** in the panel to reload workspace inventory; once the updated
identity arrives, inspection resumes.

The panel lists file status only. Use your editor or Git tools to view diffs,
stage files, or commit.

## Create a worktree from a branch

1. Select the project.
2. Press ++shift+cmd+n++ or choose the new-worktree action.
3. Choose **Branch**.
4. Search local and remote branches that are not already checked out, or type a
   new branch name.
5. Confirm.

Picking a remote branch creates a local tracking branch automatically, and the
picker distinguishes branches with the same name across remotes. Typing a name
that does not match an existing branch creates a new one.

![New worktree sheet with branch choices](/docs/assets/guide-worktree.png)

## Import a GitHub pull request

Importing a pull request requires the [GitHub CLI](https://cli.github.com/) and
Git 2.42.0 or newer on the macOS or Linux host that holds the repository (or Git
for Windows 2.53.0.windows.3 or newer on native Windows hosts). Install these on
the project's host even when Ghosthub runs on another Mac.

Sign in on that host:

```sh
gh auth login
```

If the repository uses an HTTPS Git remote, let GitHub CLI act as Git's
credential helper:

```sh
gh auth setup-git
```

Then select the project in Ghosthub, press ++shift+cmd+n++, choose **Pull
Request**, and search for an open PR. Ghosthub asks kwt to import it and opens
the new worktree session.

## Remove a worktree

Open the **…** menu beside a linked worktree (or Control-click its row) and
choose **Remove Worktree…**. After you confirm the worktree and host, Ghosthub:

1. kills that worktree's verified live tmux session if one is running; and
2. asks kwt to delete the worktree checkout.

The Git branch stays intact. If the folder is already gone, Ghosthub skips
removing it from disk while still stopping the exact live session you confirmed.
If the worktree or session changes while the confirmation sheet is open,
Ghosthub stops and asks you to confirm the updated details instead of continuing
blindly.

If the worktree has uncommitted changes, review the warning before confirming a
forced removal, which discards those changes. If there are too many changed
files to list, Ghosthub warns that the list is incomplete and still asks for
that explicit confirmation.

After removal, the parent project stays selected; Ghosthub does not jump into
another worktree or start its session automatically.

## Rearrange worktrees

Drag worktrees within a project to put them in the order you prefer. An
insertion line shows where the row will land. This only changes Ghosthub's
sidebar order; nothing in Git, kwt, or tmux is renamed or moved.

## Rust source builds

The unreleased Rust app can also register projects on connected macOS and Linux
SSH hosts. Click **+** beside that host's **Projects**, enter the repository's
full path on the remote machine, and click **Add Project**. Ghosthub installs or
repairs its remote helper automatically. If setup fails, the **Projects**
section shows the error and a **Retry** button while standalone sessions keep
working; fix the error and click **Retry** to reconnect and reload projects.

![Add a project on the Studio SSH host in the native Rust application](/docs/assets/guide-rust-remote-project.png)

![Remote project diagnostic and Retry action beside an active terminal](/docs/assets/guide-rust-project-retry.png)

Click **×** beside a project and confirm **Remove** to unregister it. Your
repository, worktrees, and running sessions stay untouched, and **Cancel** leaves
the registration as-is.

![Confirm removing the remote project registration while its terminal stays open](/docs/assets/guide-rust-remove-project.png)

Click any remote worktree or registered directory to open its session, even if
the session is stopped. Ghosthub asks kwt to open that exact workspace and
verifies the client before showing it. The Rust app supports sessions on both
the default tmux server and kwt's `kwt` server, keeping opened clients alive as
you switch rows and treating same-named sessions on the two servers separately.

![A remote worktree attached through the standard KWT server](/docs/assets/guide-rust-kwt-socket.png)

To import a pull request, click **+** beside the remote project and choose
**Pull Request**. Search open PRs or enter a PR number or URL, then click
**Import** to create the checkout and attach. GitHub access uses `gh auth login`
or `KWT_GITHUB_TOKEN` on the remote host; if listing PRs fails, the error stays
inside the dialog while your other projects stay usable.

![Import a pull request into a remote Rust project](/docs/assets/guide-rust-remote-pr-import.png)

Already-imported pull-request worktrees open from the remote project tree too.
kwt opens their protected session without running the checkout's normal layout.
Switching away and back reuses that client even if the checkout is deleted or
the project is unregistered, and the open session stays listed in the sidebar.
Detaching leaves the session running; opening a fresh client still requires the
registered project and checkout.

![An imported pull-request worktree opened on the Studio SSH host](/docs/assets/guide-rust-remote-pr-worktree.png)

To kill an open protected PR session, choose **Kill** from its **⋯** menu and
confirm **Kill Session**. You can also kill a retained session after switching
away, including from its fallback session row if the project was unregistered.
Ghosthub closes matching views across every window and leaves the checkout on
disk. If the session was replaced or the SSH connection changed, Ghosthub asks
you to review a fresh confirmation.

![Confirm killing a protected PR session over SSH](/docs/assets/guide-rust-protected-kill.png)

To create a remote worktree from a branch, click **+** beside the project, enter
a new branch name or pick an existing one (choosing the remote if more than one
has that name), and click **Create**.

![Create a remote worktree from a branch in the native Rust application](/docs/assets/guide-rust-create-worktree.png)

Ghosthub verifies the project registration and SSH connection first. If the
result cannot be confirmed, refresh the host before trying again because the
worktree may already exist. If you navigate somewhere else while creation runs,
Ghosthub respects your newer selection instead of yanking focus back.

To register a plain directory, run `kwt workspace add /absolute/path` on the
remote host, refresh that host in Ghosthub, and click its row under **Directory
Workspaces**. Ghosthub opens the session and reuses it when you switch away and
back.

![A registered remote directory opened from its idle row](/docs/assets/guide-rust-remote-directory.png)

To stop a running worktree or directory session without deleting its files, open
its **⋯** menu, choose **Kill**, and confirm **Kill Session**.

![Confirm killing a remote worktree session in the native Rust application](/docs/assets/guide-rust-project-kill.png)

Idle worktrees also work when tmux has `destroy-unattached` enabled: kwt keeps
the new session alive during setup and restores its original policy once the
first client attaches.

To remove a remote worktree, open its **⋯** menu, choose **Remove Worktree**,
review the worktree and host, and confirm. Ghosthub stops the verified session
and deletes the checkout while keeping the Git branch.

![Confirm removal of a remote worktree in the native Rust application](/docs/assets/guide-rust-remove-worktree.png)

Imported PR worktrees work the same way whether their session is open or not;
Ghosthub checks their protected socket and captures the session identity for
confirmation.

![Confirm removing an imported PR worktree over SSH](/docs/assets/guide-rust-remove-protected-worktree.png)

If a worktree has uncommitted changes, Ghosthub warns you and shows **Force
Remove Worktree**, which permanently discards staged, unstaged, and untracked
files while keeping the Git branch. Cancel to keep your edits, or commit or
stash them first for a normal removal.

![Confirm force removal of a dirty remote worktree](/docs/assets/guide-rust-force-remove-worktree.png)

Local Linux and WSL worktrees follow the exact same flow: open the **⋯** menu,
choose **Remove Worktree**, and confirm **Force Remove Worktree** if the
checkout is dirty.

![Confirm force removal of a dirty local worktree](/docs/assets/guide-rust-local-force-remove-worktree.png)

If new uncommitted changes appear after you confirmed a clean removal, Ghosthub
stops, keeps the checkout and session intact, and offers **Review Again**. If
the session, checkout, project registration, local runtime, or SSH connection
changes, refresh the host and review again. kwt also refuses removal while that
workspace session name still exists on either shared tmux server, and a failed
status check blocks removal.

Registering directories from the remote Rust UI is still in development, and
arbitrary named SSH tmux sockets are not supported.
