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
| Git indirection, repository config, hook entries, and direct hook symlink targets | Read-only when the preflight can protect every required path; transitive worktree dependencies remain writable | Host-side Git execution remains possible through writable Git metadata |
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

Apple creation copy also states that its read-only controls cover direct Git
metadata, hook entries, and direct hook symlink targets, not writable
worktree files those protected programs may invoke transitively. It does not
describe Apple as preventing every later host-side Git execution path.

## Worktree and Git Mounts

Ghosthub resolves the exact worktree path, absolute Git directory, common Git
directory, and worktree-specific Git directory from Git itself immediately
before creation. Every path must remain inside the expected local
project/worktree relationship and must still match the kwt worktree generation
the user selected. Preflight classifies one of two layouts:

- A **standard checkout** has an existing `.git` directory inside the
  worktree. Its absolute, common, and worktree-specific Git directories are the
  same directory. The worktree is the single top-level read-write mount; there
  are no gitfile, `commondir`, or `gitdir` indirection targets.
- A **linked worktree** has a regular `.git` gitfile that resolves to a
  distinct worktree-specific directory beneath the common Git directory. The
  worktree and common Git directory are separate top-level read-write mounts
  at their identical absolute host paths so every Git indirection remains
  valid inside the sandbox.

Both layouts permit direct edits, staging, commits, objects, refs, reflogs, and
the index to remain shared with the host. An unrecognized, mixed, or changing
layout fails preflight. Ghosthub does not use sbx clone mode and does not
synthesize a second Git remote.

### Apple container protection

Apple creation pins every writable ancestor directory between a protected path
and its enclosing top-level worktree or common Git mount as an explicit nested
read-write same-path mount. A mount point cannot be renamed, so a sandboxed
process cannot bypass a protected file or directory by moving an ancestor and
recreating the original path. For linked-worktree indirection, the pinned set
necessarily includes the common `worktrees` directory and exact per-worktree
Git directory. For a standard checkout, the pinned set includes its writable
`.git` directory so that directory itself cannot be replaced. Creation then
adds `--read-only-path` for the repository config, standard hooks directory,
an effective per-worktree config when enabled, every effective
repository-local included config file under a mounted root, and the currently
resolved `core.hooksPath` when that path is writable through a mounted root. A
linked worktree additionally protects its `.git` gitfile and the
worktree-specific Git directory's `commondir` and `gitdir` files. Those three
indirection files must be regular existing files whose contents resolve to the
exact worktree, worktree-specific Git directory, and common Git directory
accepted by preflight.

Preflight enumerates each existing direct entry in the effective hook
directory. For a symlink entry, it records the complete host-side symlink chain
and canonical final target. The direct entry is immutable because its hook
directory is protected. An intermediate symlink entry inside a writable
mounted root is accepted only when its parent directory is already a protected
read-only target; `--read-only-path` on the symlink itself follows its target
but does not prevent unlinking and replacing the directory entry. Any other
in-mount intermediate symlink fails closed. A final regular-file target inside
a writable mounted root joins the protected set, with its writable ancestors
pinned like any other target. A dangling or cyclic link, a final in-mount
target that is not a regular file, or a chain that cannot be canonicalized also
fails closed. A final target outside all mounted roots is recorded but does not
receive a mount because the sandbox has no host-backed path through which to
change it.

Each protected target and ancestor must already exist, remain within its
expected mounted root, and have no mutable symlink indirection that could
replace its lexical path. At the final preflight check, every protected regular
file, every regular file recursively beneath a protected directory, and every
canonical final hook target whether inside or outside the mounted roots must
have a link count of exactly one. Ghosthub rejects additional hard links rather
than trying to discover and protect aliases, because an in-mount alias can
mutate the same inode even when the canonical target is not mounted. This
deliberately rejects an additional link even when Ghosthub cannot prove that
its other name will be mounted. The provider create command must consume the
exact unchanged file identities and layout accepted by that check. Paths
outside the mounted roots are not exposed to the container.

Apple mount configuration is immutable after resource creation. Ghosthub
therefore persists the canonical accepted mount plan and repeats the complete
layout, generation, path, symlink-chain, hard-link, config, and hook preflight
immediately before every Start, including restart after reboot. Start proceeds
only when the newly computed plan exactly matches the stored plan. A mismatch
blocks Start and offers explicit Delete and Recreate; Ghosthub never silently
recreates or weakens the resource. Content changes to a still-protected target
do not by themselves change the plan, but a new target, changed symlink
resolution, additional hard link, layout change, or missing target does.

Apple's read-only-path control protects only targets that exist when the
container starts. Preflight therefore fails closed rather than claiming the
stronger capability when a layout-specific indirection, effective config, or
hook path within the mounted roots is absent, cannot be canonicalized, has an
unsafe intermediate symlink or additional hard link, changes during preflight,
or cannot be expressed as an existing read-only target. The error identifies
the Git target and path the user must review. Ghosthub does not create
placeholder Git configuration or rewrite repository metadata to make a target
mountable.

Nested file bind mounts are not used. In `container` 1.2.2, adding a nested
file bind can make the enclosing directory mount disappear, while
`--read-only-path` preserves the common Git mount and allows commits without
that failure.

### Docker sbx partial boundary

Sbx receives a standard checkout's worktree as its read-write workspace. A
linked layout additionally receives the distinct common Git directory
read-write. Both layouts add the standard hooks directory as a read-only
workspace. The hooks overlay blocks the naive or automated direct-write
pattern and is retained because it is cheap, but it is not represented as a
security barrier. Sbx 0.38 refuses a file path as a workspace, so
`.git/config` remains writable. A sandboxed process can set `core.hooksPath` to
a directory in the writable worktree and can configure `core.fsmonitor`,
`include.path`, and filter, diff, or merge drivers that execute when the user
later runs Git on the host.

The explicit boundary is: sbx protects the rest of the Mac from direct
filesystem access by the sandboxed process, but it does not protect against
host-side code execution through this repository's Git metadata. Making the
common Git directory read-only and reopening only object, ref, log, and per-worktree
directories is rejected: commits emit `packed-refs.lock` errors and some ref
operations fail, training users to ignore meaningful Git diagnostics.

Shared source has a broader consequence for both providers. A sandboxed agent
can change build scripts, editor configuration, or other executable worktree
content that the user later chooses to run on the host. Apple's Git path
protection narrows Git-metadata injection; it does not make shared source safe
to execute without review. It also does not recursively secure an interpreter,
script, library, or data file that an already-protected hook or Git config
command references from the writable worktree. A later host Git command may
execute such a transitive dependency automatically. The Apple capability is
limited to the protected metadata, direct hook entries, and direct hook
symlink targets named above.

## Git Metadata Drift Warning

Sbx records a defense-in-depth Git execution baseline at every successful
Create or explicit Start. Every baseline records whether the checkout is
standard or linked plus the resolved worktree, absolute Git, common Git, and
worktree-specific Git paths. It contains hashes, not file contents, for:

- the common repository config and effective per-worktree config
- effective repository-local included config files within the mounted roots
- for a linked worktree only, its gitfile and worktree-specific `commondir` and
  `gitdir` files
- the resolved `core.hooksPath` value
- a deterministic manifest of the resolved hook directory's file contents,
  symlink chains, relative paths, and canonical direct symlink-target contents
  when they are within a mounted root

Failure to capture a fresh baseline does not convert sbx into a stronger
boundary or silently retain an older baseline as current. The requested Create
or Start may proceed under sbx's already acknowledged partial boundary only
after Ghosthub persists a comparison-failure notice and records that no current
baseline is available.

Ghosthub compares that baseline when the sandbox terminal detaches and during
later reconciliation of a sandbox that was recorded as running. Those are
point-in-time checks while provider execution may continue. Stop and Delete
instead establish the cross-scene lifecycle fence, terminate provider
execution, confirm no sandbox process remains able to mutate the mounts, and
only then perform the final comparison. A difference produces a persistent
warning:

> Git metadata changed while this sandbox was running. The change may have
> come from the sandbox or from a host-side edit. Review the repository's Git
> configuration and hooks before running Git on the host.

This is a warning, not prevention or attribution. It cannot protect a host Git
command run before comparison, and an attacker that changes and restores the
same bytes before comparison can evade it. Failure to capture or compare a
baseline is itself a security notice and never upgrades sbx's capability
presentation. The notice retains the last known project and worktree
generation, provider, lifecycle operation, time, and comparison failure, but
never stores Git file contents. Both detected drift and comparison failure are
stored independently of the sandbox record and baseline. Stop, Delete,
stale-record removal, and worktree removal cannot erase either notice; only an
explicit user dismissal does. A failed final comparison does not prevent an
otherwise identity-verified Stop, Delete, or guarded worktree removal after the
notice has been persisted.

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
- last known lifecycle state
- the canonical immutable Apple mount plan or layout-aware sbx Git drift
  baseline, as applicable

Git-metadata drift and comparison-failure notices are separate app-owned
records, not fields whose lifetime is coupled to the managed sandbox record.

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
  resources are not auto-started after reboot or application launch. Apple
  Start repeats full preflight and requires the fresh canonical mount plan to
  match the immutable stored plan; a mismatch requires explicit recreation.
- **Stop** is confirmed because it fences and terminates sandbox processes
  while retaining provider state. After the provider confirms the resource is
  stopped, Ghosthub performs the final drift comparison and persists detected
  drift or comparison failure as a security notice.
- **Delete** is confirmed, fences execution, and removes the exact provider
  resource. After the provider confirms removal, Ghosthub performs the final
  drift comparison and persists detected drift or comparison failure as a
  security notice before removing the dedicated tmux presentation, drift
  baseline, and sandbox record.

Apple containers are expected to reconcile as stopped after a host reboot.
Ghosthub does not promise provider process restoration across reboot.

## Image Identity and Updates

Apple sandbox creation in version 1 always uses the vetted, tag-free digest
embedded from the repository-root `SANDBOX_IMAGE` file when Ghosthub is
packaged. There is no custom-image picker. Ghosthub fetches that image only
when the user first chooses Create; ordinary launch, navigation, inventory,
and worktree switching never pull an image.

Each sandbox record keeps the exact digest used at creation. When a later
packaged Ghosthub release embeds a different digest, the existing resource
remains startable at its creation digest and receives a passive **Update
Available** state. Ghosthub never replaces or recreates it automatically.
Confirmed Delete and Recreate is the only update path, and the confirmation
states that the sandbox's private home and writable root filesystem will be
discarded. The shared worktree remains governed by the ordinary guarded
worktree lifecycle.

The image's ordinary `ghosthub` user, passwordless sudo, and reviewed package
set are ergonomic defaults. They provide no privilege boundary inside the
sandbox. The Apple virtual machine and the validated immutable mount plan are
the security boundary. Developers build, vet, promote, and refresh the image
only through [Sandbox Image Operations](sandbox-image.md).

Removing a worktree uses its existing guarded confirmation and includes the
managed sandbox in that summary. Ghosthub fences reconnect, deletes the exact
verified provider resource, performs the final drift comparison, persists
detected drift or comparison failure as an independent security notice,
removes the dedicated tmux presentation and sandbox record, and only then
delegates worktree removal to kwt. A provider resource already confirmed
missing permits a best-effort final comparison, stale-record removal, and
continued worktree deletion; inability to compare is persisted before state is
removed. An unavailable provider or identity mismatch blocks the worktree
mutation because Ghosthub cannot prove that no live sandbox still mounts it.

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

Each probe creates a unique temporary repository with both its standard
checkout and a linked worktree, unique provider resources, and isolated tmux
identities, with cleanup registered before creation. It performs no push or
external credential operation.

The Apple probe asserts:

- direct editing and host-visible commits in both standard and linked layouts
- read-only repository config, standard hooks, and resolved hook path in both
  layouts, plus the linked gitfile and worktree-specific `commondir` and
  `gitdir` files
- attempts to rewrite, rename, or replace any Git indirection file fail while
  host-side Git resolution and commits continue to use the expected metadata
- attempts to rename the common `worktrees` directory or exact per-worktree
  Git directory fail because both are pinned as nested mount points
- a nested repository-local config or hook target cannot be replaced by
  renaming any writable ancestor accepted by preflight
- preflight rejects a protected file or protected-directory member with a
  pre-existing hard-link alias, and the running container cannot create a new
  hard link from a read-only target into a writable mounted root
- a direct hook symlink cannot be used to change an in-mount target, and
  changing its chain or target while stopped makes the next Start fail plan
  reconciliation
- preflight rejects an outside canonical hook target with another hard link
  and an in-mount intermediate symlink whose parent is not already read-only;
  an accepted multi-hop chain keeps every intermediate entry immutable during
  live execution
- after Stop, changing an included config or `core.hooksPath` to require a new
  protected target makes Start fail instead of restoring the stale mount plan
- a live host-side hook-directory change does not remove or weaken the overlay
- label/name inventory, stop, start, and exact deletion reconciliation

The sbx probe asserts:

- direct editing and host-visible commits in both standard and linked layouts
- the hooks workspace remains read-only before and after a live host change
- the layout-aware baseline detects changes to an in-mount direct hook symlink
  target even when the symlink text is unchanged
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
which is why Apple preflight requires existing protectable targets. A follow-up
probe on August 12 also protected the worktree gitfile and per-worktree
`commondir` and `gitdir` files. Protecting only those files still allowed the
writable per-worktree directory to be renamed; pinning both the common
`worktrees` directory and exact per-worktree directory as nested read-write
mounts closed that replacement path. Direct writes, unlinks, file renames, and
ancestor-directory renames then failed while a commit remained host-visible. A
separate nested-target probe pinned multiple writable ancestor levels for a
repository-local config file and hooks directory; ancestor renames and target
writes failed while another commit remained host-visible. A hard-link probe on
August 12 confirmed that a pre-existing writable alias bypasses
`--read-only-path`, while creating a new alias from the protected mount fails
with a cross-device-link error. This is why preflight rejects any existing
alias and the provider gate verifies that a running container cannot create
one. A standard-checkout probe pinned its `.git` directory, protected config
and hooks, rejected config writes, `.git` replacement, and new hard-link
creation, and still committed inside the container. A direct hook symlink into
the writable worktree remained mutable until its canonical target was also a
read-only path. A multi-hop follow-up showed that marking an intermediate
symlink read-only still allowed the directory entry to be unlinked and
replaced; only a read-only parent directory made that entry immutable, so v1
rejects an intermediate entry in any other writable mounted directory. An
outside canonical target also remains subject to the single-link invariant so
an in-worktree alias cannot mutate it. Separately, stopping a container,
changing `core.hooksPath`, and starting the raw provider resource restored its
stale mount plan and left the new hook directory writable. These behaviors
require direct-target protection and Ghosthub's full pre-Start plan
reconciliation. Sbx refused a config file as an additional workspace. The
rejected read-only common-Git layout committed only with `packed-refs.lock`
diagnostics. Creating an sbx sandbox with `SSH_AUTH_SOCK` removed from the
client environment still exposed the already-running daemon's forwarded agent
socket.

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
