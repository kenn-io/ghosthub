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
hosts continue to execute their own `kwt` through a login shell.

Every packaged app also carries Ghosthub's AGPL-3.0 license and all notices in
the repository's `LICENSES` directory under `Contents/Resources/Licenses`.
`LICENSES/THIRD-PARTY-NOTICES.md` is the audited inventory for GRDB, Sparkle,
and the components compiled into libghostty. Embedded libghostty is built with
internationalization disabled, so its otherwise static GNU libintl/gettext
dependency is not part of Ghosthub's app binary or release obligations.

## Reproducible inputs

`.github/workflows/release.yml` pins the release inputs that must move
deliberately:

- the full `kenn-io/kwt` source revision in `KWT_REF`
- Sparkle 2.9.4 as an exact Swift package dependency
- Xcode 26.0.1
- Zig 0.15.2 and its archive checksum
- immutable revisions for every GitHub Action

The embedded kwt revision and release-facing version are written into
`Info.plist` as `GhosthubKwtSourceRevision` and `GhosthubKwtVersion`. The
revision is also included in GitHub release notes. Kwt is part of Ghosthub's
signed code, but it remains an ordinary CLI rather than a daemon or state
authority of its own.

Because a separately installed kwt can access the same user-owned kwt state,
kwt must preserve backward compatibility for supported on-disk state and
machine-readable commands. Before advancing `KWT_REF`, test the new revision
both through Ghosthub and as a standalone CLI against representative existing
state.

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
builds the pinned kwt helper, verifies that it is an Apple Silicon Mach-O,
builds release-optimized libghostty and Ghosthub, re-signs Sparkle's nested
helpers and framework with Ghosthub's Developer ID identity, signs kwt and the
enclosing app, signs the DMG, submits it to Apple, staples and validates the
ticket, and generates an Ed25519-signed appcast. It uploads a seven-day
candidate artifact but does not create a tag or GitHub release. Both checksum
files name the DMG by basename, so they remain valid after download.

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
- A configured SSH host uses its remote kwt and tmux installations.
- **Check for Updates…** opens Sparkle's native UI without a configuration or
  signature error. A complete end-to-end installation requires a later release
  than the first version that embeds Sparkle.

## Publishing 0.1.0

Only publish after the candidate succeeds. From a clean `main` checkout:

```bash
./scripts/release.sh 0.1.0
```

The script creates and pushes annotated tag `v0.1.0`. The tag workflow rebuilds
from source, repeats signing and notarization, and creates
`https://github.com/kenn-io/ghosthub/releases/tag/v0.1.0` with:

- `Ghosthub_0.1.0_macos_arm64.dmg`
- `Ghosthub_0.1.0_macos_arm64.dmg.sha256`
- `SHA256SUMS`
- `appcast.xml`

The appcast contains only the current full DMG, embeds a link to the GitHub
release notes, and uses the tag-specific asset URL. The stable `latest/download`
feed redirects clients to this release's appcast. Publishing is aborted if the
protected private key does not match the public key embedded in the app.
Packaged apps set `SUSignedFeedFailureExpirationInterval` to `0`, so an invalid
feed never ages into Sparkle's key-rotation fallback.

Publishing is safe to rerun after a partial GitHub release failure. The
workflow reuses an existing release for the tag, refreshes its title and notes,
and replaces its assets with the newly notarized outputs.

If Apple rejects the submission, the workflow prints the notary response and
fetches the detailed notarization log before failing. It never publishes an
unsigned or unnotarized fallback artifact.

## Local packaging

Both debug and release app bundles require the kwt binary that will be embedded.
`KWT_BINARY_PATH` defaults to the developer shell's `kwt`, but an explicit path
is preferred when validating a release revision:

```bash
make release-app \
  RELEASE_APP_VERSION=0.1.0 \
  KWT_BINARY_PATH=/absolute/path/to/kwt \
  KWT_VERSION=development \
  KWT_SOURCE_REVISION=local
```

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
nested executables and services from the inside out, then kwt, then the
containing app; do not replace that release order with recursive
`codesign --deep` signing. Sparkle remains under `Contents/Frameworks`, and
SwiftPM resource bundles remain under `Contents/Resources`; placing
compatibility symlinks at the `.app` root creates unsealed content that strict
code-signing rejects. Ghosthub's AGPL license and every third-party notice in
`LICENSES` are staged during the same assembly step.

Update this document whenever release packaging, signing, notarization, the
embedded kwt policy, or `.github/workflows/release.yml` changes.
