---
description: Understand Ghosthub anonymous usage reporting and local state.
icon: lucide/shield-check
---

# Privacy

## Anonymous usage data

Packaged Ghosthub releases send at most one anonymous `application active`
event per day. The event contains:

- a random installation ID
- the Ghosthub version
- the build number

It does not contain repository, worktree, host, session, path, command, or
terminal data. PostHog person profiles and GeoIP enrichment are disabled.

Turn reporting off at any time under **Settings → Privacy → Share anonymous
usage data**.

## Local state

Ghosthub's mutable application state lives under:

```text
~/.ghosthub/
```

Ghosthub-owned terminal configuration lives separately at:

```text
~/.config/ghosthub/ghostty.conf
```

Other Ghosthub preferences, including hidden standalone tmux session patterns,
live in:

```text
~/.config/ghosthub/config.toml
```

## Remote state

Ghosthub does not scan remote filesystems. **Add Project** delegates only the
absolute repository path you explicitly provide. For configured remote macOS
and Linux hosts, Ghosthub automatically stores or updates its matching
revision-pinned managed kwt helper under the remote user's `~/.ghosthub/`
directory. Automatic Windows helper installation remains disabled.

Interactive SSH responses are retained only for the running app session.
