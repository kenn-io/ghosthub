---
title: Worktree Sandboxes
description: Provider, lifecycle, identity, terminal, and security contracts for worktree-scoped sandboxes
---

# Worktree Sandboxes

This page is the accepted implementation contract for Ghosthub-managed
worktree sandboxes. The feature is not implemented yet. It complements the
[Architecture](architecture.md), [Threat Model](threat-model.md), and
[Terminal Sessions](terminal-sessions.md) sources of truth.

## Product Boundary

One Ghosthub-managed sandbox may be associated with one exact local kwt
worktree generation. The sandbox uses that existing worktree rather than
creating a second checkout. Edits are visible on the host immediately, and Git
commits created inside the sandbox update the same branch and object database
the host sees.

Version 1 supports only the local Apple-silicon Mac and two external providers:

- Apple `container` 1.2.2
- Docker `sbx` 0.38.0

The initial version gate is an exact allowlist rather than an open-ended
semantic-version range. Adding any later provider version requires the
provider-gated integration probe described below to pass against that exact
version. Lima is a later provider and does not shape the version 1 interface.
Remote sandboxes are also deferred.

Ghosthub integrates only through each provider's CLI. It does not embed
Apple's Containerization package, Docker internals, or a provider daemon. It
does not install, update, sign in to, reset, or choose provider-wide policy for
either tool. A missing installation, unsupported version, missing Docker
login, uninitialized Docker network policy, or unhealthy provider is shown as
provider-specific setup state when the user opens the sandbox workflow.
Ordinary project, worktree, and terminal inventory remains usable.

Sandbox creation is agent-agnostic. It opens an ordinary shell by default and
may save one optional launch command. Ghosthub does not install or configure a
coding agent inside the sandbox.

## Provider Capabilities

Provider differences are explicit capabilities, following the same model as
Herdr's conditional pane-split support. They are not collapsed into a common
lowest-denominator security claim.

| Capability | Apple `container` | Docker `sbx` |
| --- | --- | --- |
| Worktree and Git metadata | Direct same-path mounts | Direct same-path workspaces |
| Existing repository config and hook paths | Read-only when the preflight can protect every effective path | Host-side Git execution remains possible through writable Git config |
| Standard `.git/hooks` directory | Read-only | Read-only defense-in-depth only |
| Host SSH agent | Not forwarded; Ghosthub never passes `--ssh` | Forwarded whenever the running sbx daemon has a host agent; no per-sandbox opt-out exists in 0.38.0 |
| Provider identity | Ghosthub label plus exact container name | Provider UUID plus exact sandbox name |

The UI must present both material sbx differences in the creation sheet, not
only in documentation:

> Docker sbx can change this repository's Git configuration, which can cause
> code to run later when you use Git on the host.

> Docker sbx exposes your host SSH agent when the sbx daemon has one. Processes
> in the sandbox can request signatures and authenticate as you wherever the
> provider's network policy allows.

Selecting sbx requires an explicit acknowledgement of this capability summary.
It is not described as equivalent to Apple's credential-off or Git-metadata
posture.

## Worktree and Git Mounts

Ghosthub resolves the exact worktree path, common Git directory, and
per-worktree Git directory from Git itself immediately before creation. Every
path must remain inside the expected local project/worktree relationship and
must still match the kwt worktree generation the user selected. The worktree
and common Git directory are mounted at their identical absolute host paths so
the linked worktree's `.git` pointer remains valid inside the sandbox.

Both providers receive the worktree and common Git metadata read-write. This
is what permits direct edits, staging, commits, objects, refs, reflogs, and the
per-worktree index to remain shared with the host. Ghosthub does not use sbx
clone mode and does not synthesize a second Git remote.

### Apple container protection

Apple creation adds `--read-only-path` for the common repository config,
standard hooks directory, an effective per-worktree config when enabled, every
effective repository-local included config file under a mounted root, and the
currently resolved `core.hooksPath` when that path is writable through a
mounted root. Paths outside the mounted roots are not exposed to the container.

Apple's read-only-path control protects only targets that exist when the
container starts. Preflight therefore fails closed rather than claiming the
stronger capability when an effective config or hook path within the mounted
roots is absent, cannot be canonicalized, changes during preflight, or cannot
be expressed as an existing read-only target. The error identifies the Git
setting and path the user must review. Ghosthub does not create placeholder Git
configuration or rewrite repository metadata to make a target mountable.

Nested file bind mounts are not used. In `container` 1.2.2, adding a nested
file bind can make the enclosing directory mount disappear, while
`--read-only-path` preserves the common Git mount and allows commits without
that failure.

### Docker sbx partial boundary

Sbx receives the worktree and common Git directory read-write plus the standard
hooks directory as an additional read-only workspace. The hooks overlay blocks
the naive or automated direct-write pattern and is retained because it is
cheap, but it is not represented as a security barrier. Sbx 0.38 refuses a
file path as a workspace, so `.git/config` remains writable. A sandboxed
process can set `core.hooksPath` to a directory in the writable worktree and
can configure `core.fsmonitor`, `include.path`, and filter, diff, or merge
drivers that execute when the user later runs Git on the host.

The honest boundary is: sbx protects the rest of the Mac from direct filesystem
access by the sandboxed process, but it does not protect against host-side code
execution through this repository's Git metadata. Making the common Git
directory read-only and reopening only object, ref, log, and per-worktree
directories is rejected: commits emit `packed-refs.lock` errors and some ref
operations fail, training users to ignore meaningful Git diagnostics.

Shared source has a broader consequence for both providers. A sandboxed agent
can change build scripts, editor configuration, or other executable worktree
content that the user later chooses to run on the host. Apple's Git path
protection narrows Git-metadata injection; it does not make shared source safe
to execute without review.

## Git Metadata Drift Warning

Sbx records a defense-in-depth Git execution baseline at every successful
Create or explicit Start. The baseline contains hashes, not file contents, for:

- the common repository config and effective per-worktree config
- effective repository-local included config files within the mounted roots
- the resolved `core.hooksPath` value
- a deterministic manifest of the resolved hook directory's file contents,
  symlink targets, and relative paths when it is within a mounted root

Ghosthub compares that baseline when the sandbox terminal detaches, before Stop
or Delete, and during later reconciliation of a sandbox that was recorded as
running. A difference produces a persistent warning:

> Git metadata changed while this sandbox was running. The change may have
> come from the sandbox or from a host-side edit. Review the repository's Git
> configuration and hooks before running Git on the host.

This is a warning, not prevention or attribution. It cannot protect a host Git
command run before comparison, and an attacker that changes and restores the
same bytes before comparison can evade it. Failure to compute or compare a
baseline is itself visible and never upgrades sbx's capability presentation.

## Credentials and Network

Ghosthub does not mount a home directory, copy credentials, provision a
credential helper, forward an SSH agent to Apple containers, or configure
provider secrets. Commits work from either provider using repository-local
identity when available. Push behavior is deliberately provider-specific:

- Apple containers normally cannot authenticate a push unless the user
  separately configures credentials through the provider or inside the
  container.
- Sbx may authenticate Git-over-SSH, SSH commit signing, or other SSH services
  through its automatically forwarded host agent. It may also expose
  provider-managed proxied or stored credentials configured outside Ghosthub.

Ghosthub never describes push as guaranteed. The host remains the recommended
place to review and push commits. Network policy is owned by the provider;
Ghosthub neither weakens nor initializes it in version 1.

## Ownership and Reconciliation

Ghosthub manages only sandboxes it created. A persistence record contains:

- an app-generated sandbox UUID
- exact kwt project and worktree generation identity
- provider and supported provider version at creation
- exact provider name and provider-reported stable identifier
- dedicated tmux socket and session identity
- optional saved launch command
- last known lifecycle state and sbx Git drift baseline

Apple resources also carry `io.ghosthub.sandbox-id=<UUID>`. Sbx has no
equivalent label in 0.38, so its provider UUID and exact generated name are
both required. A `ghosthub-` name prefix alone never authorizes adoption,
attachment, stop, restart, or deletion. Ghosthub does not discover or present
unmanaged provider resources as its own inventory.

Each refresh reconciles the persistence record with provider inventory and the
current kwt worktree generation. The UI distinguishes:

- running and stopped managed sandboxes
- a recorded sandbox missing from the provider, with **Remove Record**
- a provider resource whose recorded worktree path or generation is missing,
  with **Delete Sandbox** when provider identity still matches
- an unavailable or unsupported provider, which remains unresolved rather
  than being treated as resource deletion
- a name or identity collision, which fails closed and offers no destructive
  action against the unverified resource

Provider disappearance never silently deletes persistence. A same-path
replacement worktree never inherits the old sandbox record.

## Lifecycle

Create, Start, Open, Stop, and Delete are separate operations:

- **Create** validates the worktree generation, provider version and health,
  mount plan, capability acknowledgement, and identity before creating a
  provider resource and persistence record.
- **Open** attaches to an already running sandbox and never starts a stopped
  resource.
- **Start** is an explicit constructive action for a stopped sandbox. Provider
  resources are not auto-started after reboot or application launch.
- **Stop** is confirmed because it terminates sandbox processes while
  retaining provider state.
- **Delete** is confirmed and removes the exact provider resource, dedicated
  tmux presentation, drift baseline, and persistence record.

Apple containers are expected to reconcile as stopped after a host reboot.
Ghosthub does not promise provider process restoration across reboot.

Removing a worktree uses its existing guarded confirmation and includes the
managed sandbox in that summary. Ghosthub fences reconnect, deletes the exact
verified provider resource and its dedicated tmux presentation, removes the
sandbox record, and only then delegates worktree removal to kwt. A provider
resource already confirmed missing permits stale-record removal and continued
worktree deletion. An unavailable provider or identity mismatch blocks the
worktree mutation because Ghosthub cannot prove that no live sandbox still
mounts it.

## Terminal Presentation

A sandbox does not add a window or pane to the worktree's existing kwt tmux
session. Ghosthub creates a dedicated local tmux session on a Ghosthub-owned
sandbox socket, with names derived from the app sandbox UUID rather than user
or provider input. The first process is an ordinary interactive provider CLI
boundary—`container exec -it` or `sbx exec -it`—started in the exact worktree.
Tmux continues to own windows, panes, layout, history, key bindings, and process
lifetime, while the provider owns the sandbox VM or container.

Closing the presentation detaches only the tmux client. It does not stop or
delete the sandbox. Returning attaches to the exact existing tmux identity.
The optional saved command runs only when Ghosthub constructs a new sandbox
terminal after Create, Start, or an explicit Open that has no existing
presentation; attachment and reconnect never rerun it. If the provider stops,
the exec process and dedicated presentation may exit, but Ghosthub does not
restart either until the user chooses Start.

## Automated Provider Probes

Mount behavior is a security contract, not an assumption inferred from a
version string. `make test-sandbox-providers` will run explicit,
destructive-to-fixtures-only integration probes when its provider environment
gates are set. A requested provider probe must fail rather than skip when its
binary, authentication, policy, or runtime is unavailable.

Each probe creates a unique temporary repository and linked worktree, unique
provider resource, and isolated tmux identity, with cleanup registered before
creation. It performs no push or external credential operation.

The Apple probe asserts:

- direct worktree editing and a host-visible commit
- read-only repository config, standard hooks, and resolved hook path
- a live host-side hook-directory change does not remove or weaken the overlay
- label/name inventory, stop, start, and exact deletion reconciliation

The sbx probe asserts:

- direct worktree editing and a host-visible commit
- the hooks workspace remains read-only before and after a live host change
- repository config remains writable, preserving the declared partial
  capability rather than accidentally presenting a false stronger boundary
- stable JSON UUID/name inventory, stop, start, and exact deletion
- host SSH-agent forwarding when the dedicated test environment supplies an
  agent to the sbx daemon

Provider command construction and JSON parsing also receive deterministic unit
tests with recorded fixtures. The integration target is not part of ordinary
offline test runs, but release validation must run it whenever a supported
provider version is added.

## Validation Basis

The initial allowlist reflects hands-on validation on Apple silicon and macOS
26.5.1 on August 11, 2026. The probe used Apple `container` 1.2.2 and Docker
`sbx` 0.38.0. Both providers edited and committed through the same linked
worktree and external common Git directory. Read-only directory overlays
survived a live host-side source change in both providers.

Apple's nested file bind hid the enclosing Git-directory mount, while its
read-only-path control preserved the mount and blocked writes to existing
config and hook paths. A nonexistent read-only-path target remained creatable,
which is why Apple preflight requires existing protectable targets. Sbx refused
a config file as an additional workspace. The rejected read-only common-Git
layout committed only with `packed-refs.lock` diagnostics. Creating an sbx
sandbox with `SSH_AUTH_SOCK` removed from the client environment still exposed
the already-running daemon's forwarded agent socket.

Provider behavior and future changes should be checked against the
[Apple container releases](https://github.com/apple/container/releases),
[Apple nested-mount report](https://github.com/apple/container/issues/1890),
[Docker Sandboxes credential documentation](https://docs.docker.com/ai/sandboxes/security/credentials/),
[Docker Sandboxes release notes](https://docs.docker.com/ai/sandboxes/release-notes/),
and [Docker nested-mount report](https://github.com/docker/sbx-releases/issues/388).

## Deferred Scope

- Lima as an additional Linux-environment provider
- remote-host sandboxes
- sbx clone mode
- provider installation, update, login, secret, or network-policy management
- multiple managed sandboxes for one worktree generation
- automatic sandbox startup after reboot or app launch
