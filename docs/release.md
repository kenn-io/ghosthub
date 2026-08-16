# Ghosthub Release Playbook

Ghosthub releases are built from source in `kenn-io/ghosthub` and published to
the same repository. A release contains a signed and notarized Apple Silicon
DMG, its individual checksum, `SHA256SUMS`, and a signed Sparkle appcast.
Packaged releases check the stable feed at
`https://github.com/kenn-io/ghosthub/releases/latest/download/appcast.xml`.

The application bundles an ordinary `kwt` CLI helper at
`Ghosthub.app/Contents/Helpers/kwt`. Ghosthub invokes that exact helper for
local project inventory and worktree operations. It does not resolve a local
`kwt` from `PATH`, including when the bundle is damaged or incomplete: the
local operation fails instead of drifting to another installation. Remote
hosts use one of six pinned, CGO-disabled variants sealed under
`Contents/Resources/KwtRemote`: Darwin, Linux, and Windows, each for amd64 and
arm64.
Ghosthub uploads a variant only after the user chooses Install or Update,
verifies its SHA-256 remotely, and invokes the exact revisioned path under
`~/.ghosthub/helpers/kwt/`; it never replaces or resolves a system `kwt`.
Experimental Windows installation follows the same pinning contract through
PowerShell, placing the matching PE helper at
`%USERPROFILE%\.ghosthub\helpers\kwt\<revision>\kwt.exe`. These Windows
payloads remain unsigned until an approved Authenticode/DigiCert signing step
is added, so they are not enterprise-ready release artifacts.

`make run-app` follows the same rule. Its `bootstrap-kwt` dependency builds and
caches `KWT_REF` under `.build`, then stages that exact helper into the debug
app. A developer can override the repository, revision, source directory, or
binary path deliberately, but the default never embeds the system kwt.
`bootstrap-kwt-variants` cross-compiles the complete remote matrix from the
same pin. Each cross-compile retains its Go symbol table but omits debug
information, then inspects that actual Mach-O, ELF, or PE artifact for the
exact pinned version, revision, and revision timestamp before caching it.
Before either debug or release packaging, every variant is also checked for
its expected architecture and embedded pinned revision.

Packaging also stages libghostty's own emitted resources: the bundled Ghostty
theme corpus and shell integration at `Contents/Resources/ghostty`, and the
compiled `xterm-ghostty` terminfo database at `Contents/Resources/terminfo`.
libghostty locates them by climbing from the running executable and matching
compiled terminfo, so both trees must keep those exact names and positions.
Assembly fails rather than shipping a bundle whose themes would silently
resolve only against a user's `~/.config/ghostty/themes`.

Every packaged app also carries Ghosthub's AGPL-3.0 license and all notices in
the repository's `LICENSES` directory under `Contents/Resources/Licenses`.
`LICENSES/THIRD-PARTY-NOTICES.md` is the audited inventory for GRDB, Sparkle,
the components compiled into libghostty, and the resources the bundle
redistributes verbatim, including the iTerm2-Color-Schemes theme corpus. Embedded libghostty is built with
internationalization disabled, so its otherwise static GNU libintl/gettext
dependency is not part of Ghosthub's app binary or release obligations.

## Reproducible inputs

The root `RELEASE_VERSION` and `KWT_REVISION` files plus
`.github/workflows/release.yml` pin the
release inputs that must move deliberately:

- the release version in `RELEASE_VERSION`
- the full `kenn-io/kwt` source revision in `KWT_REVISION`
- Sparkle 2.9.4 as an exact Swift package dependency
- Xcode 26.0.1
- Zig 0.15.2 and its archive checksum
- immutable revisions for every GitHub Action

Sandbox-capable builds will also consume the root `SANDBOX_IMAGE` file as the
sole runtime image identity. Packaging reads the tag-free digest from that
file and embeds it as `GhosthubSandboxImage`; Swift, build scripts, workflows,
and documentation must not duplicate the digest literal. The provider
implementation issue `3ed9` owns that packaging boundary.

The embedded kwt revision and release-facing version are written into
`Info.plist` as `GhosthubKwtSourceRevision` and `GhosthubKwtVersion`. The
remote matrix pin is recorded independently as
`GhosthubRemoteKwtSourceRevision`, so a deliberately substituted local helper
cannot change the managed remote path. The revision is also included in GitHub
release notes. Release CI checks out that revision under
`.release-inputs/kwt-source` and passes the checkout as `KWT_SOURCE_DIR` when
building the remote variant matrix. It builds the local release helper through
`tools/build_pinned_kwt.sh`, so the helper must pass the same explicit identity
stamping and isolated daemon validation before signing. The repository slug
used by `actions/checkout` is never passed to `git clone`. Release CI records the
helper it built from the pin; a local build against a substituted
`KWT_BINARY_PATH` is recorded as `unpinned` rather than inheriting the pin. Kwt
is part of Ghosthub's signed code, but Ghosthub invokes only its CLI and never
manages its service or state directly. The pinned CLI may auto-start or reuse
kwt's same-account daemon for inventory. The pinned revision supports the
complete automation contract consumed by the app, including the isolated tmux
socket identity
returned by session-free `pr import`, the inert shell-only protected session
created or repaired by `pr attach`, and refusal to open protected imports
through kwt's ordinary default-server open paths. It also supports
`open <exact-worktree-path>`, which establishes or repairs an ordinary
workspace's canonical session and keeps its initial tmux client attached.
Exact-path resolution operates from the supplied Git worktree before global
pattern matching, so it does not depend on the configured global base when
repository-local inventory reports primary or linked worktrees stored
elsewhere. Its start-only automation mode
must never prompt for target-config trust or fuzzy layout selection; callers
may still select a deterministic layout explicitly.

Because a separately installed kwt can access the same user-owned kwt state,
kwt must preserve backward compatibility for supported on-disk state and
machine-readable commands. Before advancing `KWT_REVISION`, test the new revision
both through Ghosthub and as a standalone CLI against representative existing
state. The current pin includes kwt's provider-neutral `pr list`, `pr import`,
and `pr attach` contract; changing that contract requires
exercising candidate discovery, an idempotent existing-import result, creation
of the exact returned tmux session only on protected attachment, and a
protected attach that can re-establish an absent session without executing a
configured project layout. First attachment on a fresh protected socket must
initialize and inspect the tmux server without relying on platform-specific
connection-error text. Imports originating in an unregistered repository
must remain attachable when the recorded clone agrees with its live Git
identity, while ambiguous or conflicting registrations must fail closed.
It also includes `projects add <path> --json` as the supported registration
boundary for fresh hosts. Argument, flag, configuration, and repository
failures must retain the structured error contract, and repeated registration
must converge across clone paths using the host-aware repository identity.
The matching
`projects remove <exact-path> --expected-repository <identity>
--expected-registration <fingerprint> --json` boundary unregisters metadata
without deleting repositories, worktrees, or tmux sessions. It must accept a
missing checkout using the exact stable path, credential-free identity, and
opaque registration fingerprint published by project inventory. The daemon
serializes registration and protected project operations, verifies every
durable protected endpoint, rejects live sessions or incomplete endpoint
authority, and compare-and-swaps the registration. Missing and concurrently
changed registrations retain their structured error contracts.
The pinned-helper acceptance suite exercises registration, daemon-backed
inventory, missing-checkout removal, and another inventory request against an
isolated `KWT_HOME`.
The pinned implementation removes `KWT_GITHUB_TOKEN`, `KWT_FLEET_TOKEN`, and
the configured fleet token variable from tmux subprocess and session
environments before imported workspace panes start, while preserving
operational state such as `KWT_HOME`. Protected attachment validates the
workspace provenance, creates or repairs an inert shell-only isolated session,
and uses `attach-session -E` so a mutable `update-environment` option cannot
restore credentials. Existing sessions must carry the exact workspace marker
before reuse. The command removes the caller's parent tmux identity so the
isolated cross-server attachment also works when invoked from an existing tmux
pane.
Attachment validates the recorded project clone and exact live worktree
identity, honoring registered upstream identity for fork-origin checkouts while
excluding prunable or missing worktrees. Unreadable provenance makes inventory
fail instead of omitting the protected socket marker.
Session-start safety and configuration failures are non-retryable. Kwt also
resolves a session-local `default-shell` before falling back to the
server-global value, so every pane follows the same tmux shell policy.

### Sandbox image release inputs

`images/sandbox/APT_SNAPSHOT`, `Dockerfile`, `UBUNTU_BASE`, `VERSION`,
`packages.txt`, `tests/image-contract.sh`, and
`vulnerability-dispositions.json` are reviewed image inputs. Pull requests
require two no-cache builds with pinned BuildKit and the snapshot-derived
source epoch to have the same Docker content identity, then scan the image
without publication credentials. A merge that changes the image source builds
and checks one local image, publishes one immutable
`candidate-<full-main-commit>` digest, verifies its content identity against
that build, then creates GitHub-signed provenance and SPDX SBOM attestations
from the registry object pulled by digest. The provenance binds a deterministic
digest of every reviewed image input. Trusted promotion recomputes that digest
from `main` and rejects older candidates built from different input content.
The publishing workflow runs only on protected-`main` pushes and has no
branch-selectable dispatch; manual and pull-request validation remain in a
separate read-only workflow. Only the seven reviewed inputs trigger candidate
publication. An intended image change in Python build orchestration or other
build logic must also bump the image `VERSION` or another reviewed input;
report-and-pin merges do not publish candidates.

An Apple-silicon developer vets that exact public digest with Apple
`container` 1.2.2, then commits only its canonical report and the tag-free
`SANDBOX_IMAGE` pin on a task branch. Promotion is dispatched from trusted
`main` tooling with the exact pushed task-branch commit as inert evidence. A
repository-dispatch event fixes both the workflow source and `GITHUB_REF` to
the default branch; a caller cannot select task-branch code for a package-write
job. The workflow requires one open pull request whose complete diff is
exactly the pin and matching report at the trusted `main` revision. It rechecks
GitHub attestations and image identity, and performs a current vulnerability
rescan after approval in the protected `sandbox-image-production` environment. It
adds `vX.Y.Z` to the already tested manifest without rebuilding or wrapping it
in a new index. Candidate and production aliases are
workflow-enforced immutable policy; GHCR tag settings are not treated as the
authority. The `sandbox-image-promotion` status points to a completed
successful run of the exact trusted promotion workflow for that pull-request
head. The gate verifies that run through the GitHub API; the status alone is
not promotion authority. An active no-bypass, no-exclusion default-branch
ruleset requires the status from a dedicated status-only GitHub App with strict
checking and a single-entry merge queue. Its key is available only through a
no-reviewer environment restricted to `main`; no `GITHUB_TOKEN` receives
status-write or package-write authority. Candidate publication and production
retagging use a separate package-writer credential available only through
exact-`main` environments, and the GHCR package does not inherit repository
Actions access. Trusted promotion and every reconciliation audit the
environment, parsed workflow authority, app integration ID, and repository
policy. An organization ruleset requires the merge-signal workflow from this
repository's `main`, so merge-queue code cannot select its own signal logic.
Reconciliation fences all open heads before file inspection. The merge queue
generates a fresh SHA with its own reconciliation lane; trusted-main
tooling audits the proposed workflow tree without executing it, refuses changes
to the credential-bearing status workflow, and rechecks promotion and freshness
before authorizing it. A GitHub or API failure therefore leaves the merge
blocked. This makes the exact PR head, current `main` base, and a current
merge-time evaluation part of authorization. Main changes invalidate the
status, and successful promotion evidence expires after 24 hours.

The scheduled and manually dispatchable maintenance workflow rescans the
pinned digest with a current vulnerability database, verifies its report,
dispositions, aliases, and attestations, and reports relevant Ubuntu refresh
availability. It has no package or repository write authority and fails
visibly when operator action is required. The complete developer procedure is
[Sandbox Image Operations](sandbox-image.md).

## Protected signing environment

Create a `release-signing` GitHub Actions environment before running the
workflow. Configure it with:

- required reviewers, with self-review disabled
- deployment branches and tags restricted to `main` and `v*`
- the following environment secrets (not repository secrets)

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password used to export the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Full `Developer ID Application: … (TEAMID)` identity |
| `APPLE_API_KEY` | App Store Connect API key ID |
| `APPLE_API_ISSUER` | App Store Connect issuer UUID |
| `APPLE_API_KEY_CONTENT` | Base64-encoded `.p8` API key |
| `SPARKLE_ED_PRIVATE_KEY` | Exported Sparkle Ed25519 private seed |

The same environment has a non-secret variable named
`SPARKLE_PUBLIC_ED_KEY`. Its value must match the reviewed `SUPublicEDKey`
embedded by `tools/assemble_app_bundle.py`; appcast generation fails on a
mismatch. It also derives the public key from the protected private seed and
refuses to publish if the pair does not match. The private key's durable source
of truth is the shared Kenn Software LLC 1Password vault. Generation, custody,
restoration, and rotation follow the
[Kenn operations runbook](https://github.com/kenn-io/kenn-ops/blob/main/docs/runbooks/sparkle-update-signing.md).

The derivation guard accepts Sparkle's current exported-key format (a
base64-encoded 32-byte seed) and its legacy format (64 bytes of private material
followed by the 32-byte public key). Sparkle 2.9.4's own
`decodePrivateAndPublicKeys` routine defines those formats. Legacy records are
accepted only after the private material signs a challenge that the appended
public key successfully verifies.

Environment protection must pass before GitHub sends the job to a runner or
makes its environment secrets available. Manual candidate jobs also enforce
`refs/heads/main` in the workflow, and publication requires a tag push rather
than a manually dispatched tag.

The values are maintained in 1Password and must never be committed. Check only
the environment secret names with:

```bash
gh secret list --env release-signing --repo kenn-io/ghosthub
```

Set or replace a value directly from 1Password or an exported file. These
commands prompt for the secret when no body is provided:

```bash
gh secret set APPLE_CERTIFICATE --env release-signing --repo kenn-io/ghosthub
gh secret set APPLE_CERTIFICATE_PASSWORD --env release-signing --repo kenn-io/ghosthub
gh secret set APPLE_SIGNING_IDENTITY --env release-signing --repo kenn-io/ghosthub
gh secret set APPLE_API_KEY --env release-signing --repo kenn-io/ghosthub
gh secret set APPLE_API_ISSUER --env release-signing --repo kenn-io/ghosthub
gh secret set APPLE_API_KEY_CONTENT --env release-signing --repo kenn-io/ghosthub
gh secret set SPARKLE_ED_PRIVATE_KEY --env release-signing --repo kenn-io/ghosthub
gh variable set SPARKLE_PUBLIC_ED_KEY \
  --env release-signing \
  --repo kenn-io/ghosthub \
  --body '<reviewed public key>'
```

After all environment secrets exist, delete any repository-level copies.
Repository secrets are available when a run is queued and would bypass the
environment boundary:

```bash
for name in \
  APPLE_CERTIFICATE \
  APPLE_CERTIFICATE_PASSWORD \
  APPLE_SIGNING_IDENTITY \
  APPLE_API_KEY \
  APPLE_API_ISSUER \
  APPLE_API_KEY_CONTENT \
  SPARKLE_ED_PRIVATE_KEY
do
  gh secret delete "$name" --repo kenn-io/ghosthub
done
```

No cross-repository token is required. The workflow uses its short-lived
`GITHUB_TOKEN` with `contents: write` only when a source tag is being released.

## Candidate run

Release preparation updates `RELEASE_VERSION` and adds the matching dated
`CHANGELOG.md` section. Every packaging entry point reads that one file by
default. The Makefile passes its resolved version explicitly to the standalone
DMG and appcast scripts, and the release workflow rejects a tag whose version
does not match `RELEASE_VERSION`. Do not duplicate the current version in
scripts, workflows, tests, Makefile help, or this playbook.

After release workflow changes reach the default branch, run the manual
workflow before creating a tag:

```bash
gh workflow run release.yml \
  --repo kenn-io/ghosthub \
  --ref main
```

The manual path imports the signing certificate into an ephemeral keychain,
builds the pinned local kwt helper, verifies that it is an Apple Silicon
Mach-O, cross-compiles the Darwin/Linux/Windows amd64/arm64 remote matrix,
builds release-optimized libghostty and Ghosthub, re-signs Sparkle's nested
helpers and framework with Ghosthub's Developer ID identity, signs the local
kwt helper and both Darwin remote kwt variants with hardened runtime and secure
timestamps, then signs the enclosing app and DMG, submits it to Apple, staples
and validates the ticket, and uploads a seven-day candidate artifact. Linux
and experimental Windows remote variants remain unsigned ELF/PE resources.
The candidate does not consume
the production Sparkle private key, generate an appcast, create a tag, or
create a GitHub release. Both checksum files name the DMG by basename, so they
remain valid after download.

Download the candidate and verify either checksum from the directory that
contains the three artifact files:

```bash
version="$(tr -d '[:space:]' < RELEASE_VERSION)"
shasum -a 256 -c "Ghosthub_${version}_macos_arm64.dmg.sha256"
shasum -a 256 -c SHA256SUMS
```

Inspect the run and install the candidate on a Mac where Ghosthub has not been
locally built. Verify at minimum:

- Gatekeeper opens the app without a quarantine override.
- About Ghosthub reports the version in `RELEASE_VERSION`, Kenn Software LLC
  copyright, and the
  GNU AGPL v3.0-or-later license notice.
- Local kwt projects and worktrees load without a system kwt on `PATH`.
- Existing local tmux sessions remain discoverable and attach normally.
- A configured SSH host discovers and attaches tmux without managed kwt.
- A configured macOS or Linux host automatically receives the correct pinned
  kwt helper during inventory, while any system `kwt` remains untouched.
- A configured Windows host does not install its unsigned kwt helper
  automatically.
- On a fresh macOS or Linux host, Add Project registers an absolute existing
  checkout through managed kwt and makes its worktrees available without a
  filesystem scan.
- **Check for Updates…** opens Sparkle's native UI without a configuration or
  signature error. A complete end-to-end installation requires a later release
  than the first version that embeds Sparkle.

## Publishing

Only publish after the candidate succeeds. From a clean `main` checkout:

```bash
./scripts/release.sh
```

The script reads `RELEASE_VERSION`, then creates and pushes the matching
annotated `vX.Y.Z` tag. The tag workflow rebuilds
from source, repeats signing and notarization, generates the production-signed
appcast, and creates the matching GitHub release with:

- `Ghosthub_X.Y.Z_macos_arm64.dmg`
- `Ghosthub_X.Y.Z_macos_arm64.dmg.sha256`
- `SHA256SUMS`
- `appcast.xml`

The appcast contains only the current full DMG and embeds the exact dated
`CHANGELOG.md` section for `RELEASE_APP_VERSION`, along with a link to the
tag-specific GitHub release. Appcast generation stops before signing when that
section is missing, duplicated, empty, or malformed; it never publishes
placeholder release notes. The tag workflow also runs this same changelog
extraction as a validation step before building anything, so a bad changelog
fails the release in seconds instead of after signing and notarization.
The stable `latest/download` feed redirects clients
to this release's appcast. Publishing is also aborted if the protected private
key does not match the public key embedded in the app.
Release bundles set `SUSignedFeedFailureExpirationInterval` to `0`, so an
invalid feed never ages into Sparkle's key-rotation fallback. This is the exact
Info.plist key declared by Sparkle 2.9.4's
`SUSignedFeedFailureExpirationIntervalKey`; debug bundles omit the production
feed, public key, and automatic-update settings entirely.

Publishing is safe to rerun after a partial GitHub release failure. The
workflow reuses an existing release for the tag, refreshes its title and notes,
and replaces its assets with the newly notarized outputs.

Release binaries target macOS 15.0 and the assembled app declares the same
minimum through `LSMinimumSystemVersion`. Pull requests and `main` pushes build
the unsigned release bundle on GitHub's Apple Silicon macOS 15 image, reject
any packaged Mach-O with a newer deployment target, and run the libghostty
runtime smoke suite there. Xcode 26's separately downloaded Metal toolchain
does not activate on the hosted Sequoia image, so that job builds libghostty's
shaders with Xcode 16.4's bundled Metal compiler before compiling and packaging
Ghosthub with Xcode 26.0.1. Stable and nightly builds use that same split on
the macOS 15 runner, so the tested libghostty and Metal artifacts are the ones
that signing and notarization ship. Lowering the deployment target does not
create a separate Sequoia artifact.

If Apple rejects the submission, the workflow prints the notary response and
fetches the detailed notarization log before failing. It never publishes an
unsigned or unnotarized fallback artifact.

### Homebrew tap

The public release is consumed downstream by
[`kenn-io/homebrew-tap`](https://github.com/kenn-io/homebrew-tap). Its hourly
Linux job only checks the latest stable release metadata and exits when the
cask is current. A newer version starts the Apple Silicon macOS 26 validation
job; routine polling does not consume a macOS runner.

Before the tap can propose a cask update, the exact versioned DMG must pass all
of these gates:

- its computed SHA-256 matches the digest reported by GitHub's release API;
- `stapler` validates the ticket attached to the DMG;
- Gatekeeper accepts the DMG as `Notarized Developer ID`;
- the mounted `Ghosthub.app` passes deep, strict code-signature verification;
- Gatekeeper accepts the app as `Notarized Developer ID`;
- the app has bundle identifier `com.ghosthub` and Developer ID Team Identifier
  `2YMZH84KR8`; and
- Homebrew style, strict online audit, livecheck, install, installed-app
  verification, and uninstall all succeed against the same checksum-pinned
  artifact.

Any failure leaves the existing cask untouched and creates no pull request.
Successful update pull requests use the tap repository's workflow-scoped
`GITHUB_TOKEN`. GitHub does not automatically execute ordinary `pull_request`
workflows for pull requests created by that token; depending on repository
settings, the corresponding runs may instead appear waiting for maintainer
approval. The successful pre-PR macOS validation is therefore the authoritative
test evidence, and tap branch protection must not require an automatically
started pull-request check for these automation PRs. This boundary deliberately
avoids a personal access token, separate GitHub App, or credential in Ghosthub's
release environment.

## Nightly channel

The nightly channel is an opt-in production build of `main` for early exposure
to regressions between stable releases. It deliberately keeps the stable
`com.ghosthub` bundle identifier and app-owned state, so installing Ghosthub
Nightly replaces a stable installation at the same application path. Its
`Ghosthub Nightly` display name, About version, feed URL, and Sparkle public key
are selected at build time. Nightlies are published as releases in the separate
public `kenn-io/ghosthub-nightly` distribution repository. The canonical
`kenn-io/ghosthub` repository receives no nightly tag or release, and the
channel is not linked from ghosthub.ai or consumed by Homebrew.

`.github/workflows/nightly.yml` runs at 08:00 UTC and exits before allocating a
macOS runner when the current `main` source revision is already the completed
channel revision. A manual `workflow_dispatch` with `force: true` rebuilds that
same source for recovery. Every attempt receives a unique release tag and
immutable asset URL:

```text
nightly-<build>-<run>-<attempt>
https://github.com/kenn-io/ghosthub-nightly/releases/download/<tag>/<dmg>
```

The attempt component is mandatory even for a same-day retry: damaged bytes are
never replaced at an existing immutable URL. Publication first verifies the
downloaded workflow artifact, appcast, and checksums. It then creates a draft
release containing the immutable DMG, its checksum, `SHA256SUMS`, `appcast.xml`,
`channel.json`, and a copy named
`Ghosthub_Nightly_latest_macos_arm64.dmg`. Only after every asset is uploaded,
the authoritative manifest is revalidated, and retention succeeds does the
workflow publish the draft and mark it latest in one release transition. Thus
the `/releases/latest/download/...` feed, manifest, and bootstrap URLs switch
together. A failure before that transition deletes the candidate draft and tag
and leaves the preceding latest release authoritative.

The manifest records the source revision, monotonically increasing commit-count
build number, workflow run and candidate attempt, timestamp, immutable DMG URL,
and SHA-256. A publish-only job retry reuses that candidate attempt's verified
artifact and tag instead of substituting the retry's newer workflow-attempt
number. Eligibility validates both the manifest and appcast; a missing,
malformed, signature-incomplete, or mismatched appcast is repairable even when
the source revision has not changed. It fingerprints the prior manifest, and
publication reads that manifest again before creating and before publishing the
draft. It rejects a lower build, a conflicting source revision, or state that
differs from the eligibility fingerprint. These fences make a delayed retry
fail rather than rolling the completed channel back; workflow concurrency
prevents normal publication overlap.

Create a `nightly-signing` GitHub Actions environment with no required
reviewers and deployment branches restricted to `main`. Store these values as
environment secrets, never repository secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password used to export the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Full `Developer ID Application: … (TEAMID)` identity |
| `APPLE_API_KEY` | App Store Connect API key ID |
| `APPLE_API_ISSUER` | App Store Connect issuer UUID |
| `APPLE_API_KEY_CONTENT` | Base64-encoded `.p8` API key |
| `NIGHTLY_SPARKLE_ED_PRIVATE_KEY` | Nightly-only Sparkle Ed25519 private seed |
| `NIGHTLY_RELEASE_APP_PRIVATE_KEY` | Private key for the `kenn-dist-update-bot` GitHub App |

Configure these non-secret environment variables:

| Variable | Value |
| --- | --- |
| `NIGHTLY_SPARKLE_PUBLIC_ED_KEY` | Public key matching the nightly private seed |
| `NIGHTLY_RELEASE_APP_CLIENT_ID` | Client ID for the `kenn-dist-update-bot` GitHub App |

Keep the nightly Sparkle key, Apple credentials, and GitHub App private key in
the shared Kenn Software LLC 1Password vault. Install `kenn-dist-update-bot` on
`kenn-io/ghosthub-nightly`. The workflow exchanges its private key for a
short-lived installation token restricted to that repository and requests only
Contents write permission; no personal access token is supported or required.
GitHub Actions remains disabled in the distribution repository because all
building, signing, notarization, and publication logic lives in
`ghosthub/.github/workflows/nightly.yml`.

Cleanup retains every release attempt for the current build and the 29 highest
lower numeric builds. It ignores drafts, prereleases, and tags that do not
match the nightly tag format rather than deleting them. The release description
and repository README should continue to identify the repository as an
automated artifact host, not a source or support repository.

Stable and nightly have distinct Sparkle keys, but they share the Apple
Developer ID identity that Sparkle can use for key rotation. The separate
nightly key is therefore defense in depth. Stable-feed routing and publication
authority are the hard operational boundary: nightly credentials can write
only releases in `kenn-io/ghosthub-nightly` and cannot change the canonical
repository's stable release or appcast. The approval-gated `release-signing`
environment remains the only automated path authorized to publish stable
updates.

To enroll, quit Ghosthub and back up all state shared by the two channels:

- the resolved application-state directory (`~/.ghosthub/` by default);
- the resolved configuration directory (`~/.config/ghosthub/` by default,
  including any target selected by `init.toml` or an environment override); and
- the `com.ghosthub` preferences domain, exported with
  `defaults export com.ghosthub Ghosthub-preferences.plist`.

The latest-DMG URL is a mutable GitHub release convenience pointer that is not
trusted to authorize code. The first install does not pass through Sparkle, so
verify the DMG and mounted app's Apple Team Identifier before copying it.
Checking the DMG before mounting also rejects an otherwise valid image
notarized by another Developer ID:

```bash
bash <<'SCRIPT'
set -euo pipefail
nightly_work="$(mktemp -d -t Ghosthub_Nightly)"
nightly_dmg="$nightly_work/Ghosthub_Nightly.dmg"
nightly_mount="$nightly_work/mount"
mkdir "$nightly_mount"
cleanup() {
  hdiutil detach "$nightly_mount" >/dev/null 2>&1 || true
  rm -f "$nightly_dmg"
  rmdir "$nightly_mount" >/dev/null 2>&1 || true
  rmdir "$nightly_work" >/dev/null 2>&1 || true
}
trap cleanup EXIT

verify_team() {
  local path="$1"
  local codesign_output
  local team_id
  codesign_output="$(codesign -dv --verbose=4 "$path" 2>&1)"
  printf '%s\n' "$codesign_output"
  team_id="$(printf '%s\n' "$codesign_output" | sed -n 's/^TeamIdentifier=//p')"
  if [[ "$team_id" != "2YMZH84KR8" ]]; then
    printf 'Refusing code signed by unexpected Apple team: %s\n' "$team_id" >&2
    exit 1
  fi
}

curl --fail --location \
  --output "$nightly_dmg" \
  https://github.com/kenn-io/ghosthub-nightly/releases/latest/download/Ghosthub_Nightly_latest_macos_arm64.dmg
codesign --verify --strict --verbose=2 "$nightly_dmg"
verify_team "$nightly_dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 \
  "$nightly_dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$nightly_mount" "$nightly_dmg"
codesign --verify --deep --strict --verbose=2 "$nightly_mount/Ghosthub.app"
verify_team "$nightly_mount/Ghosthub.app"
spctl --assess --type execute --verbose=2 "$nightly_mount/Ghosthub.app"
open "$nightly_mount"
read -r -p 'After copying Ghosthub.app to Applications, press Return to unmount: ' _
SCRIPT
```

Confirm **Ghosthub Nightly** and the expected date and source revision in About
before relying on it. To leave the channel, quit the app and reinstall the
latest stable DMG from ghosthub.ai. Restore the state and configuration
directories and import the preferences with
`defaults import com.ghosthub Ghosthub-preferences.plist` only if the nightly
changed shared state incompatibly; the release process does not add a downgrade
compatibility layer. Loss of the nightly Sparkle key requires a manual
reinstall. Compromise of that key or of the nightly release credential is a
nightly release incident; compromise of the shared Apple signing identity is
an incident for both channels.

## Local packaging

Both debug and release app bundles require the local kwt binary and complete
remote variant matrix that will be embedded.
With the default `.build/kwt/kwt`, the app packaging targets verify and build
the exact `KWT_REVISION` automatically. Set `KWT_BINARY_PATH` to an existing
executable only when deliberately packaging a separately prepared build:

```bash
make release-app \
  KWT_BINARY_PATH=/absolute/path/to/kwt \
  KWT_VERSION=development \
  KWT_SOURCE_REVISION=local
```

`KWT_BINARY_PATH` changes only the local helper. Remote variants remain pinned
to `KWT_REF`; use `KWT_VARIANTS_DIR` only when deliberately supplying a
complete six-target matrix. An explicit variants directory is treated as
prebuilt input: packaging verifies all six binary formats, target
architectures, and embedded `KWT_REF`, and never rebuilds or modifies that
directory. The default variants directory continues to be built from the
pinned kwt source. Installation additionally runs the uploaded helper and
requires its first `version` line to report that exact revision before the
helper is promoted into the revisioned remote path.

`tools/build_release_dmg.sh` passes kwt overrides to the Makefile only when
they are nonempty. A clean release therefore retains these pinned defaults
instead of overriding `KWT_BINARY_PATH` with an empty value.

Unsigned DMG:

```bash
make release-dmg \
  KWT_BINARY_PATH=/absolute/path/to/kwt
```

Signed and notarized local DMG:

```bash
APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_NOTARY_KEY_FILE=/path/to/AuthKey_XXXXXXXXXX.p8 \
APPLE_NOTARY_KEY_ID=XXXXXXXXXX \
APPLE_NOTARY_ISSUER=issuer-uuid \
KWT_BINARY_PATH=/absolute/path/to/kwt \
make release-dmg
```

After the DMG is notarized, generate a local signed appcast with an exported
working copy of the Sparkle key supplied through the environment:

```bash
SPARKLE_PUBLIC_ED_KEY='<reviewed public key>' \
SPARKLE_ED_PRIVATE_KEY='<temporary private seed>' \
make release-appcast
```

Do not place the private seed directly in shell history in real operations;
load it from the protected 1Password export as described by the operations
runbook.

Outputs live in `dist/release/`. `tools/build_release_dmg.sh` signs Sparkle's
nested executables and services from the inside out, then the local kwt helper
and Darwin remote kwt resources, then the containing app. The app signature
uses `Resources/Ghosthub.entitlements` so terminal child processes can trigger
the protected-resource consent described by the app's privacy purpose strings;
keep that file aligned with the generated `Info.plist`. Do not replace the
release signing order with recursive `codesign --deep` signing. Mach-O helpers
require their own Developer ID signatures even when staged as non-executable
resources; the Linux ELF variants do not. Sparkle remains under
`Contents/Frameworks`, and SwiftPM resource bundles remain under
`Contents/Resources`; placing compatibility symlinks at the `.app` root creates
unsealed content that strict code-signing rejects. Ghosthub's AGPL license and
every third-party notice in `LICENSES` are staged during the same assembly step.

Update this document whenever release packaging, signing, notarization, the
embedded kwt policy, or `.github/workflows/release.yml` changes.
