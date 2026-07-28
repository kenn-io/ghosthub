---
title: Ghosthub
description: Worktree-centric terminal multiplexing for AI development
---

# Ghosthub

Ghosthub is a native macOS terminal workspace for developers who run many AI
agent sessions across many git worktrees. It combines libghostty terminal
surfaces, worktree-aware navigation, and ordinary tmux clients across local
and SSH hosts.

The current product is pre-release. These docs are for people building,
operating, and contributing to Ghosthub today.

## What Ghosthub Is

- A worktree-centric terminal multiplexer for macOS.
- A native Swift app built around embedded libghostty terminal surfaces.
- A control plane for local and remote tmux-backed sessions.
- A native shell over kwt worktree state and local or remote tmux sessions.

## What Ghosthub Is Not

- It is not Ghostty.app and does not read Ghostty.app configuration.
- It does not vendor a Go backend or require a git submodule checkout.
- It is not production-stable yet. Schema and API contracts are still allowed
  to change directly.

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
