---
description: Save a command to run when creating a new tmux session on a macOS or Linux SSH host.
icon: lucide/play
---

# Launch profiles

If you often start remote tmux sessions by running the same command, save it as
a launch profile. Launch profiles work on configured macOS and Linux SSH hosts.
Your local Mac and native Windows hosts do not use them.

## Save a command

1. Open **Settings → Hosts** and select a macOS or Linux SSH host.
2. Under **Launch Profiles**, click **Add Launch Profile**.
3. Enter a name and command. Both are required, and each name must be unique on
   that host.
4. Click **Done**.

For example, a profile named **Container shell** can run:

```sh
docker exec -it app-container /bin/sh
```

The command runs on the remote SSH host. In this example, Docker and the running
`app-container` must already be there.

!!! warning "Keep secrets out of commands"

    Ghosthub saves launch profile commands in local app settings, and a running
    command can show up in the remote host's process list. Never put passwords,
    tokens, or other secrets in a profile command.

## Start a session

1. Click the **+** at the right end of the host's row in the sidebar and choose
   **New tmux Session…**.
2. Enter a session name.
3. Under **Start with**, pick your profile. **Login shell** is the default.
4. Click **Create**.

![New tmux session sheet with Container shell selected](/docs/assets/docs-launch-profiles.png)

Ghosthub starts the session in an interactive terminal and runs the saved
command once when creating it. Reopening or reconnecting to that session later
does not run the command again.

## What happens if the connection drops?

If SSH drops while Ghosthub is creating the session, Ghosthub first checks
whether the session already exists on the host. If it does, Ghosthub attaches to
it. If not, the command may still have run partway before the connection broke,
so Ghosthub shows the exact original command and asks you to confirm before
running it again, even if you have edited the profile since.

If Ghosthub failed to open the terminal before starting the command at all,
**Retry** keeps your profile selection and runs it without that extra prompt.

Switching to another session leaves a pending session and any retry prompt
waiting for you when you switch back. **Command-W** detaches it. Closing a
pending session before its command starts cancels creation; use **New tmux
Session…** to try again. Once a session is running, detaching leaves the command
running inside tmux. See [Attach and detach](sessions.md#attach-and-detach).
