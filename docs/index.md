---
title: Ghosthub engineering
description: Build, maintain, and release Ghosthub.
---

# Ghosthub engineering

Ghosthub is a native macOS app for local and remote tmux, Herdr, and Zellij
sessions. These pages are for Kenn engineers and approved contributors who
build, maintain, and release it. For help using the app, read the
[public user guides](https://ghosthub.ai/docs/).

## What do you need to do?

| Task | Reference |
| --- | --- |
| Set up a Mac and build the app | [Quick start](quickstart.md) |
| Make and test a change | [Development](development.md) |
| Understand the running app and who owns its state | [Architecture](architecture.md) |
| Change shell startup, session attachment, or reconnect | [Terminal sessions](terminal-sessions.md) |
| Review a trust boundary or permission | [Threat model](threat-model.md) |
| Diagnose a build or runtime failure | [Troubleshooting](troubleshooting.md) |
| Capture the launch-profile sheet | [Launch-profile documentation](launch-profiles.md) |
| Prepare and publish a release | [Release](release.md) |
| Edit or publish documentation | [Documentation publishing](https://github.com/kenn-io/ghosthub/blob/main/docs/README.md) |

Ghosthub is alpha software. Schema and API contracts can change directly;
follow the repository rules before changing persistence.

## Other implementations and planned work

These references have their own status and scope. They do not describe features
available in the released Swift macOS app.

- [Windows and Linux Rust port](rust-port.md): the Windows/WSL2 implementation
  and its design contracts. Linux remains a build and contract-test target.
- [Worktree sandboxes](sandboxes.md): the accepted contract for a feature that
  is not implemented yet.
- [Sandbox image operations](sandbox-image.md): build and promotion procedures
  for the planned sandbox image.
- [Web UI](web-ui.md): the approved design for an additional Rust app client,
  written before implementation.
