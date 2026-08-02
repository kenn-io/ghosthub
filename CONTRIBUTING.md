# Contributing

Ghosthub is free software licensed under the GNU Affero General Public License
v3.0 (see [`LICENSE`](LICENSE)). This document covers the conventions used for
development and contribution.

## Getting set up

Follow the [Prerequisites](README.md#prerequisites) and
[Quick Start](README.md#quick-start) sections of the root README.
Deeper dev workflows, layout configuration, and end-to-end harnesses are in
[`docs/development.md`](docs/development.md).

## Workflow conventions

Two files govern day-to-day workflow:

- [`CLAUDE.md`](CLAUDE.md): quality gates, commit conventions, test
  and build commands, shell safety rules.
- [`AGENTS.md`](AGENTS.md): the source-of-truth hierarchy, test
  framework policy (Swift Testing preferred over XCTest for new
  tests), terminal-parity rules, and directory map.

Both apply to human and AI contributors; the rules are not
agent-specific.

## Quality gates

Before committing:

```bash
# Swift app
make swift-warning-check
make build
swift test

# Python tooling
make python-test

# Documentation
make docs-build
```

Run the subset that matches the files you changed. Swift app, terminal,
`Package.swift`, or bootstrap changes must leave `make build` passing.
Documentation changes should leave the Zensical build passing.

## Commit style

- Imperative mood, ≤72-character subject line, one logical change per
  commit.
- Create new commits rather than amending published ones.
- Do not push directly to `main`; use feature branches and PRs.
- Do not commit secrets, API keys, or credentials. `.env` files are
  gitignored; use environment variables for local secrets.

## Documentation

When you change architecture or feature scope, update
[`docs/architecture.md`](docs/architecture.md) in the same
change. When you change release packaging, update
[`docs/release.md`](docs/release.md). The
[`docs/README.md`](docs/README.md) index is the fastest way to find
the right document.
