---
title: Sandbox Image Operations
description: Build, vet, promote, and maintain Ghosthub's Apple sandbox image
---

# Sandbox Image Operations

Use the repository commands below for the complete image lifecycle. Do not
assemble Docker, GHCR, Apple `container`, or GitHub workflow commands by hand.
The normal two-changeset sequence is:

```text
make sandbox-image-status
make sandbox-image-refresh VERSION=X.Y.Z
make sandbox-image-check
# merge changeset one and obtain the emitted candidate digest
make sandbox-image-vet IMAGE=<candidate@digest>
make sandbox-image-pin IMAGE=<candidate@digest>
# commit and push the report-and-pin task branch
make sandbox-image-promote IMAGE=<candidate@digest> VERSION=X.Y.Z
# approve sandbox-image-production once, verify status, queue the pin PR
```

`<candidate@digest>` means the full public reference, for example
`ghcr.io/kenn-io/ghosthub-sandbox:candidate-<40-character-commit>@sha256:<digest>`.
Never use `latest`.

## Prerequisites

- Docker with Buildx for construction and registry inspection
- `uv`, `gh`, and an authenticated GitHub session for developer operations
- an Apple-silicon Mac with Apple `container` exactly 1.2.2 for vetting
- permission to push a normal task branch and dispatch the trusted workflow
- a no-reviewer `sandbox-image-package-writer` environment restricted to the
  exact `main` branch, containing `SANDBOX_PACKAGE_WRITER_USERNAME` and a
  narrowly owned classic PAT with `write:packages` in
  `SANDBOX_PACKAGE_WRITER_TOKEN`; the same two secrets also live in the
  reviewer-protected `sandbox-image-production` environment, together with
  `SANDBOX_PROMOTION_APP_ID`, `SANDBOX_PROMOTION_APP_CLIENT_ID`, and
  `SANDBOX_PROMOTION_APP_PRIVATE_KEY` for the final identity audit
- a `sandbox-image-production` GitHub environment with at least one required
  reviewer and a deployment-branch policy that admits only `main`
- the organization-owned `ghosthub-sandbox-promotion` GitHub App, installed
  only on Ghosthub with Actions, Administration, attestations, contents,
  environments, pull requests, and metadata read plus commit-status write
  permissions
- the no-reviewer `sandbox-image-promotion-status` environment, restricted by
  an exact branch policy to the `main` branch (not a same-named tag), containing
  that app's client ID and private key
- an active default-branch ruleset with no bypass actors or ref exclusions that
  requires `sandbox-image-promotion`, enables strict required-status-check
  policy, binds the context to that dedicated app's numeric integration ID,
  and requires the merge queue with one pull request per group
- an organization-owned ruleset with no bypass actors or ref exclusions that
  targets Ghosthub's default branch and requires
  `.github/workflows/sandbox-image-merge-signal.yml` from
  `kenn-io/ghosthub@refs/heads/main`
- approval authority, or an available reviewer, for that environment

The promotion preflight reads the live rulesets through the GitHub API and
fails before registry mutation if that exact required-check policy is absent.
Every reconciliation also audits both credential-bearing environments, their
exact secret sets and `main` branch policies, the status App variables, the
lack of package-writer reviewers, and the parsed structure of both `.yml` and
`.yaml` workflows. Environment-name comparisons follow GitHub's
case-insensitive semantics. Exactly
`.github/workflows/sandbox-image-promotion-gate.yml` and
`.github/workflows/sandbox-image-promote.yml` may reference the status
environment, and exactly `.github/workflows/sandbox-image-publish.yml` may
reference the package-writer environment. All three remain byte-identical to
trusted `main` when a proposed merge tree is audited. Dynamic environment
selection is rejected, every workflow must declare explicit top-level
permissions, and no workflow-level or job-level permission grants status or
package writes to `GITHUB_TOKEN`. The status job also refuses to run unless its effective ref is
`refs/heads/main`, including manual dispatches.

This gate protects a repository with one human merger from frequent agent
operation and from a tired operator merging a pin whose protected promotion
never completed. The honest simpler design is no machine gate. A check emitted
by the repository-wide GitHub Actions app is not an acceptable simplification:
branch-authored workflow code can request that same identity and forge it.

### Promotion authority bootstrap

Create the organization-owned GitHub App with webhooks disabled. Grant
repository Actions, Administration, attestations, contents, environments, pull
requests, and metadata read plus commit statuses write. Install it only on
`kenn-io/ghosthub`, then generate a private key. Configure the environment with
the repository command; the PEM contents go to `gh secret set` over standard
input and are neither printed nor placed in process arguments. GitHub App API
requests ignore the operator's curl configuration, and failures redact their
transient JSON Web Token (JWT):

```bash
make sandbox-image-authority-configure \
  APP_ID=<numeric-app-id> \
  CLIENT_ID=<app-client-id> \
  PRIVATE_KEY=</absolute/path/to/downloaded.pem>
```

After the promotion-gate and merge-signal workflows land on `main`, add the
organization ruleset's **Require workflows to pass before merging** rule. Its
source must be this repository, branch `main`, and the merge-signal workflow.
Then enable and audit the exact repository and inherited organization rules:

```bash
make sandbox-image-authority-enable
make sandbox-image-authority-audit
gh workflow run sandbox-image-promotion-gate.yml --ref main
```

Enabling the rules before their producing workflows exist would deadlock the
bootstrap pull request. The enable command verifies the inherited pull-request
policy, then creates or updates a narrow repository-owned ruleset instead of
mutating the organization's shared default-branch policy. Rerun
`sandbox-image-authority-configure` with a new PEM
to rotate the key. Before mutating GitHub, the command requires the checkout's
`origin` Git remote to be the canonical repository and uses the proposed key to
mint, audit, and revoke a short-lived
full-installation token. It then pins every variable and secret operation to
`kenn-io/ghosthub` and writes the App ID, client ID, and private key to both the
status and production environments. Only after the command succeeds should the
old key be revoked in the GitHub App settings. A fixed, checkout-free job first
mints a Ghosthub-scoped status token and fences every open pull-request head.
A separate job uses the pinned token action to mint an installation token
restricted to the read-only permissions needed by the repository audit. A
fresh checkout-free job receives the status-write token only after the audit
finishes. The App private key and status-write token are never passed to
repository Python, and repository code never runs on a runner that receives a
status-write token.

The image is public and digest pulls must work anonymously. Candidate and
production registry writes use only the protected package-writer credential,
never `GITHUB_TOKEN`. The image deliberately uses
`org.opencontainers.image.url` instead of GHCR's auto-linking
`org.opencontainers.image.source` label. Keep the package disconnected from
repository-inherited Actions access so branch workflows cannot write it even
if they request `packages: write`.

The first candidate creates a private GHCR package by default. An organization
owner must open
<https://github.com/orgs/kenn-io/packages/container/ghosthub-sandbox/settings>
and choose **Public** once. GitHub describes that visibility change as
irreversible. `make sandbox-image-status` prints the same link until package
metadata reports public visibility. The workflows never attempt to make this
owner-controlled decision.

## Changeset One: Source and Candidate

Start from a clean task branch. `sandbox-image-refresh` changes only the
independent image version, official Ubuntu 26.04 arm64 base digest, and APT
snapshot time. Review those three changes and any deliberate package or
disposition changes.

`sandbox-image-check` publishes nothing. It performs two no-cache builds with
the pinned BuildKit image and a source epoch derived from `APT_SNAPSHOT`, then
requires their Docker content identities to match. It runs the image contract,
creates an SPDX SBOM, scans operating-system packages, and applies current
dispositions. Pull requests run the same check with read-only permissions. This
reproducibility gate lets a failed publication retry accept an existing valid
candidate instead of replacing its immutable tag. The manually dispatchable
validation workflow remains read-only. After this changeset merges, the
separate `sandbox-image-publish.yml` workflow runs only from a push to protected
`main`; it has no branch-selectable dispatch. An unprivileged job builds,
checks, scans, and transfers one inert Docker archive plus its evidence to a
fresh package-writer job. That job never checks out the repository or runs its
Python, Make targets, dependency configuration, or image source. It validates
the transferred tag and content identity, exposes the GHCR credential only to
the pinned login action and fixed Docker push, logs out, then verifies the
public object by digest and records provenance and SBOM attestations. The
repository-wide token can record attestations but cannot write the GHCR
package. Provenance includes a
deterministic digest covering `APT_SNAPSHOT`, `Dockerfile`, `UBUNTU_BASE`, `VERSION`,
`packages.txt`, `tests/image-contract.sh`, and
`vulnerability-dispositions.json`. Promotion recomputes that digest from
trusted `main` and requires an exact attested match. Publication refuses to
replace a conflicting tag.

Only those seven reviewed input paths trigger candidate publication. A change
to Python build orchestration or other build logic that is intended to alter
the image must also bump `images/sandbox/VERSION` (or deliberately change
another reviewed input). Report-and-pin changes do not publish a redundant
candidate.

Candidate tags and `vX.Y.Z` production tags are immutable because repository
tooling refuses to repoint them; GHCR itself does not provide that guarantee.
If a tag already names a different digest, advance `images/sandbox/VERSION`
and repeat the lifecycle. Never repair the conflict with an ad hoc retag.

## Changeset Two: Vet, Pin, and Promote

Run `sandbox-image-vet` against the exact public candidate digest. It verifies
the attestations, pulls for `linux/arm64`, exercises the image through Apple
`container`, tests Stop/Start persistence, and validates standard and linked
Git mount protection in disposable repositories. Cleanup identity is written
before creation. A failure still writes
`images/sandbox/reports/sha256-<digest>.json` for diagnosis and returns
nonzero.

Vetting repeats the Git metadata write and move probes after Stop/Start. A
provider version whose read-only overlays do not survive restart therefore
cannot produce a passing report.

Review the report's digest, source commit, image/provider/macOS versions,
required checks, scan timestamp, findings, and dispositions. It must not
contain a username, host path, credential, environment dump, or repository
content. A disposition is a committed record in
`images/sandbox/vulnerability-dispositions.json` with an owner, rationale, and
expiration. Its identity is the exact vulnerability ID, package, Trivy result
class and type, and scan target. Trivy OS-package targets are normalized to the
stable `rootfs` identity so archive names and temporary registry aliases do not
change disposition matching; language-package targets retain their binary or
manifest path. Findings from OS packages and language
runtimes embedded in binaries follow the same policy, but a disposition for one
binary or ecosystem cannot authorize another. A fixable Critical or High
finding always blocks; an unfixed one needs a current exact disposition.

The developer who runs `sandbox-image-vet` and the protected-environment
reviewer are trusted operators. GitHub-hosted promotion cannot authenticate
that a contributor-generated report came from an Apple runtime, so the
reviewer must approve only a report they produced or whose local vet run they
independently witnessed. Promotion rejects a report or scan database older
than seven days; cryptographically signed Apple-runner evidence is deferred.

`sandbox-image-pin` reevaluates that evidence and writes only the tag-free
`SANDBOX_IMAGE`. Commit the pin and its one canonical report together, push
the task branch, and open the pull request through the normal human review
path. Do not change that head after promotion. A new head has no promotion
success and requires a new version and a complete repeat.

`sandbox-image-promote` refuses a dirty, detached, default, or unpushed branch
and emits the `sandbox-image-promote` repository event. GitHub binds a
repository-dispatch run to the default branch, so neither the operator command
nor the Actions UI can select task-branch workflow code. The protected workflow
requires the supplied commit to be the current head of exactly one open pull
request targeting the same trusted `main` revision, with a complete diff
containing only the pin and canonical report. It never checks out or executes
task-branch content. A read-only planning job independently verifies both
GitHub attestations and image source/version labels, rescans the exact candidate
with the current vulnerability database, and prepares an inert retag plan.
Planning refuses evidence or a disposition that cannot remain valid for the
full 24-hour status lifetime, while promotion authorization ends after 23
hours. The plan also fingerprints the complete
reviewer, deployment, and branch policy plus the status-signing environment;
delayed approval cannot extend the window, change who may approve it, or widen
access to the status-signing key.
Approve the `sandbox-image-production` environment deployment once that plan
passes. The approved job starts on a fresh runner and rescans the exact
candidate digest with a checksum-pinned Trivy release, an empty cache, and the
trusted-main dispositions before it receives any App or registry credential.
It then cryptographically rechecks
the organization-owned App identity, owner, slug, permissions, and complete
single-repository installation scope, the exact production credential set,
both required repository rulesets, the status-signing environment, and the
unchanged trusted-main workflow authority, then revalidates the pull-request
evidence, candidate alias, and production-tag availability immediately before
copying the existing manifest without creating a new index. Repository Python
and its dependencies never run on the approved runner. Only fixed workflow
commands receive the GHCR credential, copy the exact digest, and log out. The
workflow verifies both aliases and records an App-authenticated fingerprint of
the approved production policy on that exact head.
The pull-request gate accepts that status only when its timestamp and target
identify the completed successful trusted promotion run for the same evidence
and base commits and the fingerprint matches the current audited production
environment. Main changes invalidate it, and an hourly guard
ages the run from its immutable creation time and uses a conservative 23-hour
cutoff to leave one hour of scheduling margin before the 24-hour limit. If the
run expires before retag or merge, rerun
`sandbox-image-promote` and approve the idempotent promotion again.

The repository ruleset must require this status from the dedicated app with
strict checking enabled, no bypass actors, an empty exclusion list, and a
single-entry merge queue. Queue the pull request with **Merge when ready**
rather than merging its head directly. The organization ruleset separately
requires the merge-signal workflow pinned to trusted `main`. The queue creates
a fresh synthetic SHA; that pinned workflow requests a SHA-specific
reconciliation.
Trusted-main code checks out the proposed merge tree without executing it,
structurally audits every proposed workflow, and requires every workflow that
can reference a credential-bearing environment to remain byte-identical to
trusted `main`. The audit rejects job-level reusable workflows except the
exact repository-owned `ci.yml@main` call, and it keeps the merge-signal name,
trigger, and file byte-identical to trusted `main`.
It then rechecks the complete App, environment, ruleset, file, base,
promotion-run, and freshness authority before the dedicated App authorizes that
queue SHA. If GitHub cannot run reconciliation, the queue SHA never succeeds
and times out closed. Strict checking also makes the current `main` revision
part of authorization. Any push creates a new head without authorization.
Trusted promotion verifies the same live authority before it can write a
production tag.

The pull-request gate runs only for pull requests targeting `main`. Every open,
head update, reopen, ready-for-review transition, or edit fences every open head
pending before it inspects file metadata. Push, schedule, workflow completion,
and manual events perform the same full reconciliation. Merge-signal events use
an isolated lane that fences and reconciles only their own queue SHA. Recurring
reconciliation also fences prior queue SHAs and restores only a recently
audited authorization that still satisfies current policy. A pull request whose file list exceeds
GitHub's 3,000-file API limit remains pending without preventing other pull
requests from being reconciled. Only current evidence from the trusted
default-branch promotion workflow may cause the dedicated App to record success
on either a pull-request head or its fresh merge-group SHA.

## Status, Recovery, and Maintenance

`make sandbox-image-status` is read-only. It reports the source version, app
pin, report, aliases, and first-package setup state. `make
sandbox-image-clean` removes only Apple vet fixtures whose persisted name and
both provider labels agree; unknown or partially matching resources are
reported and never deleted. Use those commands after an interrupted vet. Do
not use `container delete --all` or handwritten cleanup commands.

After the first production pin exists, manually dispatch
`sandbox-image-maintenance.yml` once before relying on its weekly schedule.
The job verifies the report, production alias, and trusted-main provenance and
SBOM attestations against the report source commit and current reviewed-image
input digest. It then rescans with the current Trivy database, checks dispositions, and reports whether a
current Ubuntu snapshot offers a named fix. It uploads the vulnerability JSON
and fails loudly when action is required. It never builds, publishes, retags,
refreshes, or edits a pin.

Finally, log out of GHCR if necessary and prove anonymous consumption with the
supported provider path:

```bash
container image pull --platform linux/arm64 "$(tr -d '[:space:]' < SANDBOX_IMAGE)"
```
