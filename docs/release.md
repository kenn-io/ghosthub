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
same pin. Before either debug or release packaging, every variant is checked
for its expected Mach-O/ELF/PE architecture and embedded pinned revision.

Every packaged app also carries Ghosthub's AGPL-3.0 license and all notices in
the repository's `LICENSES` directory under `Contents/Resources/Licenses`.
`LICENSES/THIRD-PARTY-NOTICES.md` is the audited inventory for GRDB, Sparkle,
and the components compiled into libghostty. Embedded libghostty is built with
internationalization disabled, so its otherwise static GNU libintl/gettext
dependency is not part of Ghosthub's app binary or release obligations.

## Reproducible inputs

The root `KWT_REVISION` file and `.github/workflows/release.yml` pin the
release inputs that must move deliberately:

- the full `kenn-io/kwt` source revision in `KWT_REVISION`
- Sparkle 2.9.4 as an exact Swift package dependency
- Xcode 26.0.1
- Zig 0.15.2 and its archive checksum
- immutable revisions for every GitHub Action

The embedded kwt revision and release-facing version are written into
`Info.plist` as `GhosthubKwtSourceRevision` and `GhosthubKwtVersion`. The
remote matrix pin is recorded independently as
`GhosthubRemoteKwtSourceRevision`, so a deliberately substituted local helper
cannot change the managed remote path. The revision is also included in GitHub
release notes. Release CI checks out that revision under
`.release-inputs/kwt-source` and passes the checkout as `KWT_SOURCE_DIR` when
building the remote variant matrix; the repository slug used by
`actions/checkout` is never passed to `git clone`. Release CI records the
helper it built from the pin; a local build against a substituted
`KWT_BINARY_PATH` is recorded as `unpinned` rather than inheriting the pin. Kwt is part of Ghosthub's
signed code, but it remains an ordinary CLI rather than a daemon or state
authority of its own. The pinned revision supports the complete automation
contract consumed by the app, including the isolated tmux socket identity
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

After release workflow changes reach the default branch, run the manual
workflow before creating a tag:

```bash
gh workflow run release.yml \
  --repo kenn-io/ghosthub \
  --ref main \
  -f version=0.1.0
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
shasum -a 256 -c Ghosthub_0.1.0_macos_arm64.dmg.sha256
shasum -a 256 -c SHA256SUMS
```

Inspect the run and install the candidate on a Mac where Ghosthub has not been
locally built. Verify at minimum:

- Gatekeeper opens the app without a quarantine override.
- About Ghosthub reports version 0.1.0, Kenn Software LLC copyright, and the
  GNU AGPL v3.0-or-later license notice.
- Local kwt projects and worktrees load without a system kwt on `PATH`.
- Existing local tmux sessions remain discoverable and attach normally.
- A configured SSH host discovers and attaches tmux without managed kwt.
- Install kwt Worktree Helper selects the correct target, enables remote project
  inventory, and leaves any system `kwt` untouched.
- On a fresh macOS or Linux host, Add Project registers an absolute existing
  checkout through managed kwt and makes its worktrees available without a
  filesystem scan.
- **Check for Updates…** opens Sparkle's native UI without a configuration or
  signature error. A complete end-to-end installation requires a later release
  than the first version that embeds Sparkle.

## Publishing 0.1.0

Only publish after the candidate succeeds. From a clean `main` checkout:

```bash
./scripts/release.sh 0.1.0
```

The script creates and pushes annotated tag `v0.1.0`. The tag workflow rebuilds
from source, repeats signing and notarization, generates the production-signed
appcast, and creates
`https://github.com/kenn-io/ghosthub/releases/tag/v0.1.0` with:

- `Ghosthub_0.1.0_macos_arm64.dmg`
- `Ghosthub_0.1.0_macos_arm64.dmg.sha256`
- `SHA256SUMS`
- `appcast.xml`

The appcast contains only the current full DMG, embeds a link to the GitHub
release notes, and uses the tag-specific asset URL. The stable `latest/download`
feed redirects clients to this release's appcast. Publishing is aborted if the
protected private key does not match the public key embedded in the app.
Release bundles set `SUSignedFeedFailureExpirationInterval` to `0`, so an
invalid feed never ages into Sparkle's key-rotation fallback. This is the exact
Info.plist key declared by Sparkle 2.9.4's
`SUSignedFeedFailureExpirationIntervalKey`; debug bundles omit the production
feed, public key, and automatic-update settings entirely.

Publishing is safe to rerun after a partial GitHub release failure. The
workflow reuses an existing release for the tag, refreshes its title and notes,
and replaces its assets with the newly notarized outputs.

If Apple rejects the submission, the workflow prints the notary response and
fetches the detailed notarization log before failing. It never publishes an
unsigned or unnotarized fallback artifact.

## Local packaging

Both debug and release app bundles require the local kwt binary and complete
remote variant matrix that will be embedded.
With the default `.build/kwt/kwt`, the app packaging targets verify and build
the exact `KWT_REVISION` automatically. Set `KWT_BINARY_PATH` to an existing
executable only when deliberately packaging a separately prepared build:

```bash
make release-app \
  RELEASE_APP_VERSION=0.1.0 \
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
  RELEASE_APP_VERSION=0.1.0 \
  KWT_BINARY_PATH=/absolute/path/to/kwt
```

Signed and notarized local DMG:

```bash
APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_NOTARY_KEY_FILE=/path/to/AuthKey_XXXXXXXXXX.p8 \
APPLE_NOTARY_KEY_ID=XXXXXXXXXX \
APPLE_NOTARY_ISSUER=issuer-uuid \
KWT_BINARY_PATH=/absolute/path/to/kwt \
make release-dmg RELEASE_APP_VERSION=0.1.0
```

After the DMG is notarized, generate a local signed appcast with an exported
working copy of the Sparkle key supplied through the environment:

```bash
SPARKLE_PUBLIC_ED_KEY='<reviewed public key>' \
SPARKLE_ED_PRIVATE_KEY='<temporary private seed>' \
make release-appcast RELEASE_APP_VERSION=0.1.0
```

Do not place the private seed directly in shell history in real operations;
load it from the protected 1Password export as described by the operations
runbook.

Outputs live in `dist/release/`. `tools/build_release_dmg.sh` signs Sparkle's
nested executables and services from the inside out, then the local kwt helper
and Darwin remote kwt resources, then the containing app; do not replace that
release order with recursive `codesign --deep` signing. Mach-O helpers require
their own Developer ID signatures even when staged as non-executable resources;
the Linux ELF variants do not. Sparkle remains under `Contents/Frameworks`,
and SwiftPM resource bundles remain under `Contents/Resources`; placing
compatibility symlinks at the `.app` root creates unsealed content that strict
code-signing rejects. The containing app is signed with
`Resources/Ghosthub.entitlements`, which grants camera and audio-input access
only so WebKit can present the system permission flow for websites opened in
Web Preview. Its `Info.plist` also permits arbitrary loads only inside WebKit so
the explicitly entered HTTP development addresses supported by Web Preview do
not relax App Transport Security for Ghosthub's other network clients.
Ghosthub's AGPL license and every third-party notice in `LICENSES` are staged
during the same assembly step.

Update this document whenever release packaging, signing, notarization, the
embedded kwt policy, or `.github/workflows/release.yml` changes.
