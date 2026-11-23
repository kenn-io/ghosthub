---
description: Anonymous usage reporting, macOS permission prompts, and where Ghosthub stores local and remote files.
icon: lucide/shield-check
---

# Privacy

## Anonymous usage data

Packaged Ghosthub releases send at most one anonymous `application active` ping
per day (on by default). That ping includes only:

- a random installation ID
- the Ghosthub version
- the build number

It never includes repositories, worktrees, hosts, session names, paths,
commands, or terminal output. PostHog person profiles and GeoIP lookups are
turned off.

To opt out at any time, turn off **Settings → Privacy → Share anonymous usage
data**.

![Privacy settings with Share anonymous usage data enabled](/docs/assets/guide-privacy.png)

## macOS permissions

Programs running inside Ghosthub can ask macOS for access to Photos, the camera,
microphone, contacts, calendars, or files. macOS names Ghosthub in those prompts
because Ghosthub is the app hosting the terminal. Check what the program
actually needs before clicking Allow.

## Local files

Ghosthub stores its app state (database, caches, and update metadata) under:

```text
~/.ghosthub/
```

Ghosthub's libghostty terminal config lives separately at:

```text
~/.config/ghosthub/ghostty.conf
```

Other app settings, including hidden standalone tmux session patterns and custom
shortcuts, live in:

```text
~/.config/ghosthub/config.toml
```

## Remote files

Ghosthub never scans remote filesystems. **Add Project** registers only the
exact repository path you give it. On configured macOS and Linux SSH hosts,
Ghosthub automatically installs and updates its matching revision-pinned kwt
helper under the remote user's `~/.ghosthub/` folder. Automatic installation is
off for Windows hosts.

Interactive SSH prompts (passwords, passphrases, and challenge responses) stay
in memory only for the current app run.
