---
title: Ghosthub engineering
description: Build, maintain, and release Ghosthub.
---

# Ghosthub engineering

Ghosthub is a native hub for local and remote tmux, Herdr, and Zellij sessions
(macOS Swift app, plus a Rust port for Windows and Linux). These pages are for
Kenn engineers and approved contributors who build, test, and release it. For
help using the app, see the [public user guides](https://ghosthub.ai/docs/).

## What do you need to do?

| Task | Reference |
| --- | --- |
| Set up a Mac and build the app | [Quick start](quickstart.md) |
| Make, format, and test a change | [Development](development.md) |
| Understand app architecture and state ownership | [Architecture](architecture.md) |
| Change shell startup, attachment, or reconnect | [Terminal sessions](terminal-sessions.md) |
| Review a trust boundary or permission | [Threat model](threat-model.md) |
| Diagnose a build or runtime failure | [Troubleshooting](troubleshooting.md) |
| Capture the launch-profile screenshot | [Launch-profile documentation](launch-profiles.md) |
| Prepare and publish a release | [Release](release.md) |
| Edit or publish documentation | [Documentation publishing](https://github.com/kenn-io/ghosthub/blob/main/docs/README.md) |

Ghosthub is under active development and some internal contracts still evolve
directly; check the repository rules in `AGENTS.md` before changing
persistence.

## Other implementations and planned work

These pages have their own status and scope and do not describe features in the
released Swift macOS app:

- [Windows and Linux Rust port](rust-port.md): native Windows/WSL2 and Linux
  apps, build instructions, and remaining parity work.
- [Web UI](web-ui.md): approved pre-implementation design for a loopback web UI
  served by the Rust app.
