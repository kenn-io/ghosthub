# Ghosthub Sandbox Image Design

**Status:** Approved design for Kata issue `8ems`

## Summary

Ghosthub will publish one small, vetted Linux image for version 1 Apple
`container` sandboxes. The image is an ergonomic environment, not the sandbox
security boundary. The Apple virtual machine and Ghosthub's validated mount
plan provide that boundary.

Version 1 deliberately does not expose an image picker. Every newly created
Apple sandbox uses the exact digest in the repository-root `SANDBOX_IMAGE`
file. A sandbox persists the digest used at creation, remains startable after
the repository pin changes, and shows **Update Available** when the two differ.
Updating is an explicit, confirmed Delete and Recreate operation that discards
the sandbox's private home and root filesystem.

The source, build pipeline, vetting evidence, promotion policy, and operator
scripts live in the Ghosthub repository. Developers use short Make targets for
the entire lifecycle; neither a human nor an agent should need to assemble
Docker, GHCR, Apple `container`, or GitHub workflow commands by hand.

## Goals

- Give an agent a practical shell, Git, network bootstrap tools, a writable
  persistent home, and the ability to install additional software when needed.
- Keep the shipped environment small and agent-agnostic.
- Make the exact runtime artifact reviewable and reproducible enough to audit.
- Vet the same digest that is promoted and eventually pinned by the app.
- Make release and maintenance failures loud, diagnosable, and non-mutating.
- Preserve Ghosthub's fast normal navigation: image discovery, pulling,
  probing, and updates never occur synchronously during ordinary worktree or
  tab switching.

## Non-goals

Version 1 does not provide custom images, multiple architectures, automatic
image updates, credential forwarding, migration of an existing sandbox's home
or root filesystem, a bundled coding agent, Docker-in-Docker tooling, cosign
signatures, sbx image reuse, or Lima integration. It targets local Apple
silicon only.

## Approach

Three approaches were considered:

1. **Repository-owned Dockerfile, digest pin, and promotion pipeline.** This
   keeps source review, runtime identity, operational tooling, and evidence in
   one repository while preserving OCI portability. This is the selected
   approach.
2. **Build directly through Apple `container`.** This reduces local tooling
   but couples publication to an Apple-only builder and makes hosted Linux CI
   less useful. It is rejected as the authoritative build path.
3. **Use a general upstream development image.** This avoids image ownership
   but gives Ghosthub no stable package, user, provenance, or update contract.
   It is rejected.

The authoritative build uses an OCI Dockerfile through BuildKit. Apple
`container` is the runtime-vetting authority. The separation is intentional:
the build remains portable and repeatable in CI, while the provider-specific
test proves the actual runtime contract on an allowlisted Apple stack.

## Source and Identity

Image source lives under `images/sandbox/`:

```text
images/sandbox/
├── Dockerfile
├── VERSION
├── UBUNTU_BASE
├── APT_SNAPSHOT
├── packages.txt
├── vulnerability-dispositions.json
├── reports/
└── tests/
```

The three identity layers are independent:

- **Source identity:** the full Ghosthub commit used for the candidate build.
- **Release identity:** the `X.Y.Z` value in `images/sandbox/VERSION`.
- **Runtime identity:** the OCI `sha256` manifest digest in the root
  `SANDBOX_IMAGE` file.

`SANDBOX_IMAGE` contains one canonical reference with no tag:

```text
ghcr.io/kenn-io/ghosthub-sandbox@sha256:<64 lowercase hex characters>
```

The digest is the only runtime authority. Tags are discoverable release
aliases. Candidate tags use `candidate-<full-source-commit>`, production tags
use `vX.Y.Z`, and no `latest` tag is published. Both classes are anonymously
pullable. Only protected workflows may publish or promote.

Candidate and production tag immutability is workflow-enforced policy, not a
GHCR guarantee. A script accepts an existing tag only when it already resolves
to the requested digest and otherwise fails without replacing it. Every job
that can publish or retag this package shares the repository-wide
`sandbox-image-package-writer` concurrency group, queues without cancellation,
rechecks the target tag immediately before mutation, and resolves it again
afterward. The lock and final checks close the concurrent-writer race that a
standalone check-before-write cannot prevent.

The image carries standard OCI source, revision, version, and description
labels. A candidate's source label, provenance attestation, tag, version, and
vetting report must agree before promotion.

## Image Construction

The image targets `linux/arm64` and uses Ubuntu 26.04 LTS. `UBUNTU_BASE` pins
the official arm64 base manifest digest. `APT_SNAPSHOT` pins the Ubuntu archive
snapshot used during the build. Build scripts pass both values explicitly;
the Dockerfile does not contain a second copy.

The reviewed package inventory is limited to:

- `bash`
- `git`
- `ca-certificates`
- `curl`
- `openssh-client`
- `sudo`
- `unzip`
- `xz-utils`

Dependencies pulled by those packages are permitted and visible in the SBOM.
The image does not intentionally include an agent, compiler toolchain,
language runtime, editor, Docker CLI, or credential helper. A package is added
only when an approved image-contract test demonstrates that the base and
current inventory cannot satisfy a required behavior. For example, Ubuntu
26.04 arm64 currently supplies `tmux-256color` through `ncurses-base`, so
`ncurses-term` is not added unless the pinned candidate fails the terminfo
contract.

The build uses the pinned snapshot only for bootstrap package installation and
then restores ordinary live Ubuntu repositories. This makes the reviewed
inputs stable without freezing a user's later `apt` operations. The project
does not promise byte-identical rebuilds: BuildKit, package metadata, and
registry serialization may still differ. Supply-chain authority comes from
building once, attesting that candidate digest, vetting it, and promoting that
same digest without rebuilding.

The image defines a non-root `ghosthub` user with a private home and
passwordless `sudo`. This is convenience, not privilege separation; the user
can become root inside the VM. The default locale is `C.UTF-8`. No host home,
SSH agent, credentials, Git global configuration, or Git identity is copied
into the image. Git commits depend on repository-local identity when present.

The image default command is `/bin/sleep infinity`, which only keeps the
resource available for later execs. The provider create command uses Apple
`container create --init`, whose init forwards signals and reaps orphaned
processes. The image does not bundle a second init. Ghosthub also explicitly
execs interactive processes as `ghosthub`; it does not rely on provider
defaults.

## Runtime Contract

The image tests and Apple vetting establish these observable behaviors:

- The image manifest is `linux/arm64` only.
- The reviewed packages are installed and intentionally excluded toolchains,
  agents, editors, and Docker CLI are absent.
- The normal interactive identity is `ghosthub`, its home is private and
  writable, and passwordless `sudo` works.
- `LANG` selects UTF-8 and a terminfo entry exists for every `TERM` Ghosthub's
  dedicated sandbox tmux presentation can set. Version 1 defines that value as
  `tmux-256color`.
- HTTPS through the system CA bundle, SSH client startup, shell basics, Git
  status, and a commit with repository-local identity work.
- Live Ubuntu repositories work after construction, including installing a
  package not present in the image.
- A test writes a home marker and installs a small marker package, performs a
  real provider Stop and Start, and confirms both persist.
- The provider runs with `--init`, forwards termination correctly, and reaps a
  deliberately orphaned child.
- Interactive exec selects `ghosthub` explicitly.

The `--init` and explicit-user checks join the exact-version command fixtures
and live probes in `3ed9`. Adding an Apple `container` version to the allowlist
requires these behaviors to pass for that exact version.

The image test is not a substitute for the sandbox provider probe. The
provider probe also exercises the standard and linked-worktree mount plans,
Git commits, read-only Git targets and indirection files, hard-link and symlink
rejections, Stop/Start reconciliation, and the threat boundaries already
specified in `docs/sandboxes.md`.

## Publication Pipeline

### Pull requests

A pull request that touches `images/sandbox/**`, the image tooling, or its
workflows builds the arm64 image, runs the image contract, produces an SPDX
JSON SBOM with a repository-pinned Trivy release, and scans the result with
the same tool. It publishes nothing. Unrelated pull requests do not run the
image pipeline.

### Candidates

After an image-source change lands on `main`, the candidate workflow builds
once and publishes:

```text
ghcr.io/kenn-io/ghosthub-sandbox:candidate-<full-source-commit>
```

Unrelated `main` commits publish nothing. The workflow binds GitHub artifact
provenance and an SBOM attestation to the candidate digest. Fixable Critical
or High vulnerabilities block publication. An unfixed Critical or High is
permitted only through a current committed disposition; Medium and Low remain
visible and non-blocking.

### Local vetting

On an Apple-silicon Mac, the developer vets the exact public candidate digest,
not a local rebuild. Vetting verifies digest identity and attestations, then
runs the full Apple runtime checklist in a dedicated managed fixture. It
always writes a diagnostic JSON report, even on failure, to:

```text
images/sandbox/reports/sha256-<64 lowercase hex characters>.json
```

Only a passing report with valid dispositions may proceed. The report is then
committed with `SANDBOX_IMAGE`, so the reviewer sees the runtime evidence,
provider and macOS versions, scan result, and dispositions in the same diff as
the runtime pin.

### Promotion

The approved order is:

1. Vet the exact candidate digest locally.
2. Prepare `SANDBOX_IMAGE` and its canonical report on a task branch.
3. Open or update a pull request and push a clean commit containing both.
4. Dispatch the promotion workflow from `main`, passing the exact pushed task
   commit, candidate digest, and requested image version as inputs.
5. The `main`-pinned workflow and tooling verify that the input commit is the
   current head of one open pull request targeting `main`, that its source diff
   contains only `SANDBOX_IMAGE` and the canonical report, and that the digest,
   candidate tag, source/version identity, provenance, SBOM attestation,
   committed report binding, and vulnerability dispositions agree. It reads
   the pin and report from that commit strictly as data; it never checks out or
   executes task-branch code.
6. The human performs one protected GitHub environment approval.
7. After approval, the workflow rechecks that the input commit is still the
   pull request head, enters the shared package-writer group, rechecks both
   aliases, adds `vX.Y.Z` to the already-vetted digest without rebuilding, and
   verifies that it resolves to the digest in `SANDBOX_IMAGE`.
8. Promotion records required `sandbox-image-promotion` success on that exact
   pull-request head. The report-and-pin pull request may merge only while that
   status is required and current; the merged digest-only pin then becomes
   Ghosthub's runtime authority.

A `pull_request_target` gate from `main` records that status as pending for any
pull request whose complete diff touches `SANDBOX_IMAGE` or a canonical image
report. It never checks out or executes pull-request code. The promotion
workflow is the only path that changes the pending status to success after the
production alias verifies. The same gate records success immediately for
unrelated pull requests, so making the context a default-branch requirement
does not add sandbox-image steps to ordinary development. The first production
promotion must add the context to the default-branch ruleset after its first
successful status and before the pin merges; subsequent runs verify that
protection is still active.

Hosted CI cannot rerun the Apple-silicon `Virtualization.framework` runtime
check. Promotion validates the committed local evidence; it does not claim to
re-vet runtime behavior.

The production alias may exist briefly before the pin pull request merges. A
new pull-request commit has no promotion success status and is therefore
unmergeable. It may not reuse or repoint the immutable production alias; the
developer advances the image version and repeats vetting and promotion. An
unmerged production alias never becomes Ghosthub runtime authority because
`SANDBOX_IMAGE` remains unchanged on `main`.

### Weekly maintenance

Once the first production digest exists, a scheduled and manually
dispatchable workflow rescans the pinned digest with a current vulnerability
database, validates its report and dispositions, checks its production tag,
and reports whether a newer Ubuntu base or snapshot contains relevant fixes.
It never rebuilds, publishes, promotes, changes a version, or edits a pin.

Required action fails the workflow visibly, writes a concise job summary, and
retains the machine-readable scan artifact. The operator can obtain the same
state through `make sandbox-image-status`. Acceptance manually dispatches this
workflow once against the first production digest so its success and alarm
path are tested before the weekly schedule is trusted.

All workflows use SHA-pinned actions, `persist-credentials: false`, minimal
permissions, and `id-token: write` only in jobs that create attestations. They
must pass zizmor. Privileged promotion always executes the workflow and
implementation pinned by `main`; the status gate also comes from `main`, and
task-branch files are inert evidence only. Digest authority plus GitHub's
signed provenance and SBOM attestations is sufficient for version 1; separate
cosign signing is deferred.

## Operator Interface

One repository-owned Python entry point, executed through `uv`, implements the
lifecycle. It may delegate pure parsing, policy, report, and
command-orchestration logic to focused modules; the single entry point is an
interface guarantee, not a requirement to accumulate the implementation in
one file. Make targets are the stable human interface:

- `make sandbox-image-check`
- `make sandbox-image-refresh VERSION=X.Y.Z`
- `make sandbox-image-vet IMAGE=<candidate-or-repository@digest>`
- `make sandbox-image-pin IMAGE=<candidate-or-repository@digest>`
- `make sandbox-image-promote IMAGE=<candidate-or-repository@digest> VERSION=X.Y.Z`
- `make sandbox-image-status`
- `make sandbox-image-clean`

The scripts resolve every tag to a digest immediately and pass digests between
steps. `pin` normalizes its input to the tag-free repository digest used in
`SANDBOX_IMAGE`.

### `check`

Build the image with BuildKit, run its image contract, generate the SBOM, scan
it, and validate source files and dispositions. Publish nothing.

### `refresh`

Resolve and validate a newer official Ubuntu 26.04 arm64 base digest and
archive snapshot, set the requested independent image version, and leave a
reviewable working-tree diff. Never commit, tag, publish, promote, or edit
`SANDBOX_IMAGE`.

### `vet`

Pull and inspect the exact candidate digest, verify its attestations, run the
complete Apple runtime checklist, write the canonical report, and remove its
managed fixtures. A failure still writes the report and exits unsuccessfully.

### `pin`

Require a passing canonical report for the exact digest, normalize the image
reference, and prepare the report plus `SANDBOX_IMAGE` for review. Never
commit, push, promote, or merge.

### `promote`

Require a clean task branch whose exact HEAD is already pushed and contains
the matching report and pin. Dispatch the protected workflow from `main` with
that commit as the evidence input. The command itself does not approve the
environment, grant the required head status, or merge the pull request.

### `status`

Report source version, pinned digest, candidate and production aliases,
attestations, report state, disposition state, weekly-scan state, and whether
refresh, vetting, promotion, or pin work remains. Once promoted, it requires
the `vX.Y.Z` alias to resolve to the pinned digest and the default-branch
ruleset to require `sandbox-image-promotion` on the current pin pull-request
head until merge.

### `clean`

Delete only temporary provider resources carrying Ghosthub's complete,
verified vet-fixture identity. Refuse missing, partial, mismatched, or unknown
identity. Print the managed residue and corrective action when cleanup cannot
complete automatically.

The scripts provide direct prerequisite and recovery messages. Developers do
not need to copy ad hoc provider, registry, scanner, or workflow commands.

## Reports and Vulnerability Dispositions

The vetting report schema records:

- schema version
- image repository and manifest digest
- image version and source commit
- candidate tag and attestation identities
- macOS version, architecture, and exact Apple `container` version
- each runtime assertion and its result
- vulnerability scan summary and database timestamp
- each applied disposition
- overall pass/fail result and completion time

Reports never contain usernames, home paths, credentials, environment dumps,
or captured Git contents. Commands redact known sensitive values before
recording bounded diagnostic output.

Structured dispositions live in:

```text
images/sandbox/vulnerability-dispositions.json
```

Each entry identifies the vulnerability and affected package, gives a
rationale and owner, and has an ISO date expiry. `check`, `vet`, promotion, and
weekly maintenance consume the same file. An expired, malformed, duplicate,
or unmatched disposition fails closed. Adding or extending one is a reviewed
source diff. The generated report embeds the exact dispositions it applied so
promotion can prove that the evidence and current policy agree.

## Failure Semantics

- Build, contract, scan, attestation, report-binding, and tag-conflict failures
  publish or retag nothing.
- A failed vet writes diagnostic evidence but cannot be pinned or promoted.
- An existing tag with the requested digest is idempotent; an existing tag
  with another digest is a hard conflict.
- Promotion refuses a dirty tree, an unpushed commit, a commit other than the
  current report-and-pin pull-request head, a source diff outside the pin and
  canonical report, or evidence produced for another digest.
- Candidate publication and promotion serialize every package mutation,
  recheck tag state inside the shared lock, and verify the resulting tag before
  reporting success.
- Cleanup runs after successful and failed vetting. Unremoved managed residue
  is visible in `status` and removable with `clean`.
- Unknown provider resources are never adopted or deleted.
- Weekly findings are durable failed workflow runs with summaries and retained
  artifacts, not quiet logs.
- An image-pin update is passive. Existing sandboxes remain usable at their
  creation digest until the user confirms destructive Delete and Recreate.

## Delivery

Implementation ships as two task-branch pull requests because publishing
machinery must be present on `main` before a candidate can exist.

### Changeset one: source and machinery

- Image source, pinned inputs, package inventory, contract tests, and the
  disposition file.
- Python lifecycle tooling and thin Make targets.
- Pull-request checks, candidate publication, protected promotion, and weekly
  maintenance workflows.
- Focused Python tests plus pinned ruff and ty gates.
- `docs/sandbox-image.md` as the operator guide, linked from
  `docs/release.md`.
- Canonical product decisions in `docs/sandboxes.md`: vetted-image-only
  creation, no image picker, digest authority through `SANDBOX_IMAGE`,
  per-sandbox creation digest, passive update availability, and confirmed
  destructive Delete/Recreate as the only update path.
- Threat-model wording that treats the image's user and package choices as
  ergonomics, not an additional security boundary.

This changeset contains no Swift UI, persistence, or provider implementation.
After it merges, its `main` commit publishes the first candidate.

### Changeset two: evidence and runtime pin

The developer uses the supported lifecycle to vet the candidate, creates a
task branch containing its report and `SANDBOX_IMAGE`, opens the second pull
request, and pushes the exact commit. Promotion is dispatched from the trusted
`main` workflow with the task commit as inert evidence. After environment
approval, production-tag verification, and the required promotion status on
that exact pull-request head, the pull request merges. This dogfoods the
release process on its first use while preserving the rule that task work
never commits or pushes directly to `main`.

The merged pin unblocks the Apple provider-contract implementation in `3ed9`.

## Testing and Acceptance

The Python executable module ships with deterministic pytest coverage for
Ghosthub-owned behavior: image-reference normalization, pin/report binding,
report schema validation, disposition matching and expiry, and tag-conflict
decisions. Tests run through `make python-test`. They do not mock tests of
BuildKit, registries, scanners, workflow YAML, or Apple provider behavior;
those boundaries are exercised by the real check, workflow, and vet paths.
Pinned ruff and ty checks cover Python lint and typing.

Acceptance requires:

- The image contract and focused Python tests pass.
- Ruff, ty, and zizmor pass.
- The public candidate has valid provenance and SBOM attestations.
- The committed report records a passing Apple-silicon vet on the exact
  allowlisted provider version.
- Locale, terminfo, explicit user, passwordless sudo, Git, live package
  installation, `--init`, and mount-hardening assertions pass.
- A real Stop/Start preserves both the home marker and installed marker
  package.
- Candidate and production tags resolve to the pinned digest.
- Candidate and promotion writer jobs use the shared non-canceling package
  queue, and neither reports success until its alias resolves back to the
  intended digest.
- The default-branch ruleset requires `sandbox-image-promotion`; the exact pin
  pull-request head has success, and a different head does not inherit it.
- An anonymous pull by digest succeeds.
- `status` reports a fully promoted, current image.
- `clean` leaves no managed vetting fixtures.
- A manual weekly-maintenance dispatch against the first production digest
  passes, or a deliberately induced safe fixture condition fails loudly with
  the expected summary and artifact before the schedule is trusted.
- `make docs-build`, repository commit hooks, and applicable repository checks
  pass.

No website screenshot is required because changeset one exposes no user-facing
UI. The later sandbox acceptance issue `wke9` owns Guide updates and screenshot
publication when the native workflow is implemented and accepted.

## Issue Boundaries

- `8ems` owns this image, its lifecycle scripts, reports, workflows, operator
  documentation, and the first production pin.
- `3ed9` consumes `SANDBOX_IMAGE` and owns provider command construction,
  exact-version capability probes, `--init`, explicit exec-user behavior, and
  image/mount runtime validation.
- `t8qh` persists each sandbox's creation digest and reconciled provider
  identity.
- `ek7x` owns Start, Stop, Delete/Recreate, update-available behavior, and the
  dedicated tmux presentation.
- `zetz` owns the creation and update UI.
- `wke9` owns end-to-end acceptance, website Guide changes, and final
  screenshots.

Post-version-1 credential ergonomics remain in `yqyr`, project-scoped sbx
groups remain in `cky5`, and unavailable-provider deletion recovery remains in
`drzt`.
