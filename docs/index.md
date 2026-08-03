---
title: Ghosthub
description: Internal engineering guide for Ghosthub
---

# Ghosthub

Ghosthub is a native macOS terminal for local and remote tmux fleets. It gives
equal status to ordinary tmux sessions and sessions bound to managed git
worktrees, all presented through libghostty terminal surfaces.

Ghosthub is alpha software. These are internal engineering docs for Kenn
engineers and approved contributors building, operating, and releasing it.

## What Ghosthub Is

- A native terminal and control plane for local and remote tmux sessions.
- A native Swift app built around embedded libghostty terminal surfaces.
- A manager for optional worktree-bound sessions and their lifecycle through
  kwt, including branch and GitHub pull-request imports.

## What Ghosthub Is Not

- It is not Ghostty.app and does not read Ghostty.app configuration.
- It does not vendor a Go backend or require a git submodule checkout.
- It is alpha software. Schema and API contracts are still allowed to change
  directly.

## Runtime Shape

```text
Ghosthub.app
  ├─ SwiftUI/AppKit workspace shell
  ├─ libghostty terminal surfaces
  ├─ local app persistence
  ├─ native tmux clients with SSH reconnect
  ├─ bundled kwt for local worktree state
  └─ managed architecture-matched kwt and host tmux over SSH
```

Start with [Quick Start](quickstart.md), then read
[Architecture](architecture.md), [Threat Model](threat-model.md), and
[Terminal Sessions](terminal-sessions.md) before changing runtime, security,
or terminal behavior.
