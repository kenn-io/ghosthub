# Launch Profiles

Launch profiles save the command that should become the first process in a new
tmux session. They are available for the local Mac and for macOS or Linux hosts
reached through SSH. Windows hosts ignore POSIX launch profiles.

![A new tmux session sheet with the Container shell launch profile selected](https://raw.githubusercontent.com/kenn-io/ghosthub/refs/heads/website-assets/docs-launch-profiles.png?asset=docs-launch-profiles)

## Configure a profile

1. Open **Settings → Hosts**.
2. Select the host and find **Launch Profiles**.
3. Add a profile with a nonempty name and command. Profile names must be unique
   for that host.
4. Arrange profiles in the order you want them to appear in session creation.

For example, a profile named **Container shell** can run:

```sh
docker exec -it app-container /bin/sh
```

!!! warning "Keep secrets out of commands"
    Ghosthub stores profile commands in local app settings, and the host's
    process list may expose a running command. Do not include passwords, tokens,
    or other credentials.

## Start a session with a profile

1. Select the **+** beside **Tmux Sessions** for the target host.
2. Enter the new session name.
3. Under **Start with**, select the saved profile. **Login shell** remains the
   default.
4. Choose **Create**.

For an SSH host, Ghosthub allocates the remote PTY before it starts the command,
so interactive programs can use the terminal normally. The selected command is
run only while establishing that new tmux session.

After Ghosthub discovers or reconciles the created session, every later
connection is attach-only. Reconnects never run the saved command again, and
existing sessions are always attach-only even when profiles are configured.

If SSH drops while Ghosthub is still establishing a profile-backed session, it
probes the host before recovering. When the session is present, Ghosthub
replaces the interrupted presentation with an attach-only connection. When the
session is absent, Ghosthub does not repeat the saved command automatically
because the first attempt may already have produced side effects. The
confirmation shows the exact command retained from the interrupted attempt,
even if the profile has since changed. Review that command and explicitly
confirm before running it again.

If Ghosthub cannot create the terminal presentation before the command starts,
**Retry** preserves the selected profile and runs its command without an extra
confirmation. The destructive confirmation appears only after a launch attempt
may have produced side effects.

Switching to another host, worktree, or session hides the profile-backed
terminal without detaching it. Ghosthub keeps its presentation and recovery
supervisor alive, and returning to it reuses the same client. If an interrupted
command needs confirmation, navigating elsewhere does not discard the retained
command or its confirmation state.

Pressing **Command-W** detaches the active presentation. Closing its workspace
window or quitting Ghosthub detaches every presentation that workspace owns.
Tmux still owns the session and its processes, so none of these actions stops
the session or the command running inside it. If **Command-W** closes a pending
profile-backed creation before its command starts, Ghosthub abandons that
creation and removes its optimistic session entry; use **New tmux session** to
start it again.

## Reproduce the screenshot

The checked-in renderer hosts the real SwiftUI sheet with a deterministic
**Container shell** profile and captures it without launching or activating the
app:

```sh
website/demo/render-launch-profile.sh
```

The generated image defaults to
`/private/tmp/ghosthub-doc-assets/docs-launch-profiles.png`. The published copy
lives on the orphan `website-assets` branch so the documentation does not add
large binaries to the application history.
