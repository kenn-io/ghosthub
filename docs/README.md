# Ghosthub Documentation

The maintained docs are a Zensical site rooted in this directory.

## Site Pages

- [`index.md`](index.md) - internal-user overview
- [`quickstart.md`](quickstart.md) - prerequisites and first build
- [`architecture.md`](architecture.md) - product and architecture source of truth
- [`threat-model.md`](threat-model.md) - security boundaries and trusted-peer assumptions
- [`terminal-sessions.md`](terminal-sessions.md) - terminal ownership, shell startup, and restart semantics
- [`development.md`](development.md) - local development workflow
- [`troubleshooting.md`](troubleshooting.md) - common bootstrap and runtime failures
- [`release.md`](release.md) - signing, notarization, and release packaging

## Build

```bash
make docs-build
make docs-serve
```

The build wrapper creates a temporary docs input tree and excludes generated
`site/`, virtual environments, caches, and support files. Durable technical or
user-facing decisions belong in the maintained pages above rather than in
checked-in implementation plans.

## Agent-Facing Files

These stay at the repo root because agent tooling discovers them there:

- [`../AGENTS.md`](../AGENTS.md) - mandatory agent workflow and mental model
- [`../CLAUDE.md`](../CLAUDE.md) - development workflow, build commands, quality gates
