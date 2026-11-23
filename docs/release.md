# Ghosthub release playbook

Ghosthub releases are built from source in `kenn-io/ghosthub` and published to
the same repository: a signed and notarized Apple Silicon DMG, its individual
checksum, `SHA256SUMS`, and a signed Sparkle appcast. Packaged stable builds
check `https://github.com/kenn-io/ghosthub/releases/latest/download/appcast.xml`.

## Release a new version

1. Update `RELEASE_VERSION` and add the matching dated section to
   `website/docs/content/changelog.md` (plain language, leading with what users
   and agents can do). Review the public guides and
   [refresh screenshots](https://github.com/kenn-io/ghosthub/blob/main/website/README.md#product-screenshots)
   only if accepted changes altered what those screenshots show.
2. Validate the prep PR and merge it with repository-owner authorization.
3. Run the [signed candidate](#candidate-run) from `main` and verify it on a
   Mac that has never built Ghosthub before tagging.
4. [Publish the tag](#publishing) from that same clean `main` commit. The
   workflow rebuilds, signs, notarizes, and publishes the DMG, checksums, and
   appcast.
5. Verify the published assets and appcast version, then
   [deploy the website](https://github.com/kenn-io/ghosthub/blob/main/website/README.md#deployment)
   (pushing `website-assets` alone does not deploy the site).

Report the candidate, published release, and deployed website separately; a
queued workflow is not a published release.

## What ships in the app

- **Local kwt helper:** bundled at `Ghosthub.app/Contents/Helpers/kwt` and
  invoked by exact bundle path for local project inventory, worktrees, and SSH
  route resolution. Never falls back to `kwt` on `PATH`, even if damaged.
- **Remote kwt matrix:** six CGO-disabled variants sealed under
  `Contents/Resources/KwtRemote` (`darwin`, `linux`, `windows` x `amd64`,
  `arm64`). On configured macOS/Linux hosts, Ghosthub auto-installs and
  verifies the matching helper at `~/.ghosthub/helpers/kwt/<revision>/kwt`
  without touching system `kwt`. Windows hosts use explicit PowerShell install
  to `%USERPROFILE%\.ghosthub\helpers\kwt\<revision>\kwt.exe` and remain
  unsigned until Authenticode signing is added.
- **Compiler pin (`KWT_GO_VERSION`):** `make run-app`, `bootstrap-kwt`,
  `bootstrap-kwt-variants`, and CI all select `KWT_GO_VERSION` via
  `GOTOOLCHAIN` (included in cache stamps). Currently pinned to **Go 1.27.4**,
  the oldest release accepted by pinned kwt, preserving the
  [eMudhra certificate verification fix](https://go.dev/doc/devel/release#go1.27.3)
  from Go 1.27.3. Inspect built helpers with `go version -m .build/kwt/kwt` and
  run `make test-essential-workflows` after bumping Go. Every cross-compiled
  Mach-O/ELF/PE keeps Go symbols (omitting DWARF) and is verified for target
  architecture, version, revision, and timestamp before caching and packaging.
- **libghostty resources:** stages the theme corpus and shell integration at
  `Contents/Resources/ghostty` and compiled `xterm-ghostty` terminfo at
  `Contents/Resources/terminfo` (assembly fails if missing).
- **Licenses:** stages `Ghosthub-Apache-2.0.txt` and all notices from
  `LICENSES/` (including `THIRD-PARTY-NOTICES.md` for GRDB, Sparkle,
  libghostty components, and iTerm2-Color-Schemes) under
  `Contents/Resources/Licenses`. Embedded libghostty disables i18n so GNU
  libintl/gettext is not linked.
- **Rust helper bundles:** Linux and Windows Rust builds embed the
  `KWT_REVISION` / `KWT_GO_VERSION` remote matrix for macOS/Linux (`x86_64`,
  `arm64`) via `make rust-build` / `tools/build_rust_kwt.ps1` (Cargo validates
  architecture, revision, and SHA-256; release builds reject missing helpers;
  `GHOSTHUB_KWT_VARIANTS_DIR` overrides with a prebuilt matrix). Not yet
  published as Linux release packages; see [Rust port](rust-port.md#native-linux-ssh-sessions).

## Reproducible inputs

Pinned release inputs live in `RELEASE_VERSION`, `KWT_REVISION`,
`KWT_GO_VERSION`, `Vendor/ghostty.version.json`, `mise.toml`, and
`.github/workflows/release.yml`:

- release version in `RELEASE_VERSION`
- full `kenn-io/kwt` commit in `KWT_REVISION`
- Go compiler in `KWT_GO_VERSION`
- Sparkle `2.10.0` (exact SwiftPM dependency)
- Xcode `26.0.1`
- libghostty from Ghostty `1.4.0` and Zig `0.17.0` in
  `Vendor/ghostty.version.json` (plus matching `mise.toml` and
  `.github/zig.sha256`; PR CI reads both from the PR checkout while running
  `main`'s `.github/workflows/ci.yml`)
- SHA-pinned GitHub Actions

### Pinned kwt provenance and contract

`Info.plist` records `GhosthubKwtSourceRevision`, `GhosthubKwtVersion`, and
independently `GhosthubRemoteKwtSourceRevision` (so a substituted local
`KWT_BINARY_PATH` is marked `unpinned` without altering the managed remote
matrix). Release CI checks out `KWT_REVISION` into `.release-inputs/kwt-source`
and builds via `tools/build_pinned_kwt.sh` (never passing a checkout slug to
`git clone`).

Before advancing `KWT_REVISION`, test both through Ghosthub and standalone
against representative user state. The pinned revision must preserve:

- local SSH route resolution (`ssh -G`) with fail-closed behavior and no
  fallback to `PATH` or a Swift `ssh -G` parser;
- `pr list`, session-free `pr import` (returning required `tmux_attach_mode`
  and isolated `tmux_socket_name`), and inert shell-only `pr attach` (stripping
  `KWT_GITHUB_TOKEN`, `KWT_FLEET_TOKEN`, and configured fleet token variables
  while keeping `KWT_HOME`, checking workspace markers, clearing parent tmux
  identity, and attaching with `attach-session -E`);
- `open <exact-worktree-path>` (exact-path resolution before global patterns,
  non-prompting start-only mode, dedicated `kwt` server with adoption of
  verified default-server sessions, session-local `default-shell` preference);
- `projects add <path> --json` and guarded
  `projects remove <exact-path> --expected-repository <identity> --expected-registration <fingerprint> --json`
  (daemon-serialized, accepting missing checkouts, rejecting live protected
  sessions, bare `.git` repo support).

## Protected signing environment

All signing, notarization, and publishing jobs in `release.yml` and
`nightly.yml` guard with `github.repository == 'kenn-io/ghosthub'` (enforced by
`tools/tests/test_workflow_fork_guards.py`) so forks skip them cleanly while
keeping PR validation jobs open.

Keep the `release-signing` GitHub Actions environment restricted to `main` and
`v*`, owner-operated, with these environment secrets (never repository secrets):

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password used to export the `.p12` |
| `APPLE_SIGNING_IDENTITY` | Full `Developer ID Application: … (TEAMID)` identity |
| `APPLE_API_KEY` | App Store Connect API key ID |
| `APPLE_API_ISSUER` | App Store Connect issuer UUID |
| `APPLE_API_KEY_CONTENT` | Base64-encoded `.p8` API key |
| `SPARKLE_ED_PRIVATE_KEY` | Exported Sparkle Ed25519 private seed |

Set the non-secret environment variable `SPARKLE_PUBLIC_ED_KEY` to match the
`SUPublicEDKey` embedded by `tools/assemble_app_bundle.py`. Appcast generation
derives the public key from `SPARKLE_ED_PRIVATE_KEY` (supporting both Sparkle's
32-byte seed format and legacy 64+32-byte format with challenge-signature
verification) and aborts on any mismatch. Private keys live in the Kenn
Software LLC 1Password vault; custody and rotation follow the
[Kenn operations runbook](https://github.com/kenn-io/kenn-ops/blob/main/docs/runbooks/sparkle-update-signing.md).

Inspect or update environment secrets via `gh`:

```bash
gh secret list --env release-signing --repo kenn-io/ghosthub
```

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

Remove any repository-level copies so they cannot bypass environment protection:

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

No cross-repo token is needed for stable releases; the tag job uses its
short-lived `GITHUB_TOKEN` (`contents: write`).

## Candidate run

After release prep (`RELEASE_VERSION` + dated changelog entry) lands on `main`,
trigger a signed candidate build before tagging:

```bash
gh workflow run release.yml \
  --repo kenn-io/ghosthub \
  --ref main
```

The candidate job imports the cert into an ephemeral keychain, builds the
pinned local kwt helper and six-target remote matrix, builds release libghostty
and Ghosthub, signs Sparkle's nested components, local kwt, Darwin remote kwt
variants, the app, and the DMG with hardened runtime and secure timestamps,
notarizes and staples the DMG, and uploads a 7-day candidate artifact (without
consuming the Sparkle key, generating an appcast, tagging, or creating a GitHub
release).

Verify the downloaded candidate on an Apple Silicon Mac that has never built
Ghosthub (SSH is fine; requires Xcode or Command Line Tools for ticket check):

```bash
version="$(tr -d '[:space:]' < RELEASE_VERSION)"
gh run download <run-id> --repo kenn-io/ghosthub --dir candidate
scp -r candidate tools/verify_release_candidate.sh <clean-mac>:
ssh <clean-mac> "sh verify_release_candidate.sh candidate/* $version"
```

`tools/verify_release_candidate.sh` verifies both checksums, quarantines the
DMG, checks the stapled notarization ticket, Gatekeeper `Notarized Developer ID`
acceptance on both DMG and app, strict deep signature, bundle ID `com.ghosthub`,
team `2YMZH84KR8`, version `RELEASE_VERSION`, and a runnable bundled kwt helper
(printing `PASS` only if all hold). When packaging, signing, kwt helpers, or
Sparkle changed, also launch the candidate manually and verify About, local/SSH
tmux attach, remote kwt install, and **Check for Updates…**.

## Publishing

After the candidate passes, run from a clean `main` checkout:

```bash
./scripts/release.sh
```

This reads `RELEASE_VERSION` and pushes the annotated `vX.Y.Z` tag. The tag
workflow extracts and validates the changelog section up front (failing in
seconds if missing, duplicated, empty, or malformed), rebuilds, signs,
notarizes, generates the signed appcast, and publishes the GitHub release with:

- `Ghosthub_X.Y.Z_macos_arm64.dmg`
- `Ghosthub_X.Y.Z_macos_arm64.dmg.sha256`
- `SHA256SUMS`
- `appcast.xml`

Key release safeguards:

- **Sparkle config:** release bundles set
  `SUSignedFeedFailureExpirationInterval` to `0` so invalid feeds never age
  into key-rotation fallback; debug bundles omit feed, public key, and
  auto-update settings entirely.
- **Rerunnable publishing:** rerunning after a partial GitHub release failure
  reuses the tag's release, updates its notes, and replaces its assets.
- **macOS 15.0 floor:** release binaries target macOS 15.0
  (`LSMinimumSystemVersion`). Because Xcode 26's separate Metal toolchain does
  not activate on the hosted macOS 15 runner, CI builds libghostty shaders with
  Xcode 16.4's bundled Metal compiler and compiles/packages Ghosthub with Xcode
  26.0.1, then verifies every packaged Mach-O deployment target and runs the
  libghostty smoke suite on Sequoia.
- **Notarization and stapling:** Apple rejection prints the detailed notary log
  and fails closed (never publishing an unnotarized artifact).
  `tools/stapler.sh` retries transient ticket-service failures (exit 68) up to
  3 times (10s, 20s backoff), fails immediately on invalid tickets, and requires
  ticket validation plus Gatekeeper assessment before writing checksums.

### Homebrew tap

[`kenn-io/homebrew-tap`](https://github.com/kenn-io/homebrew-tap) polls stable
release metadata hourly on Linux and triggers Apple Silicon macOS 26 validation
only when a newer version appears. Before proposing a cask PR, the exact DMG
must pass:

- SHA-256 match against the GitHub release API digest;
- `stapler` ticket validation and Gatekeeper `Notarized Developer ID` on both
  the DMG and mounted `Ghosthub.app`;
- strict deep signature check, bundle ID `com.ghosthub`, and Team ID
  `2YMZH84KR8`;
- Homebrew style, strict online audit, livecheck, install, installed-app check,
  and uninstall.

Any failure leaves the existing cask untouched. Update PRs use the tap's
`GITHUB_TOKEN`, so pre-PR macOS validation is the authoritative check (tap
branch protection must not require an auto-triggered `pull_request` check on
those bot PRs).

## Nightly channel

Nightlies are opt-in production builds of `main` published to the separate
public `kenn-io/ghosthub-nightly` repo (never linked from ghosthub.ai or
Homebrew). They share `com.ghosthub` and `~/.ghosthub/` state (replacing a
stable install at the same path) while using display name **Ghosthub Nightly**,
their own feed URL, and their own Sparkle Ed25519 key. Sparkle nightly dialogs
format the build date and numeric build number (`CFBundleShortVersionString`
stays `RELEASE_VERSION`; `CFBundleVersion` stays the commit count). Update
relaunch window-frame capture runs in the outgoing app (so the first update
from a pre-capture build cannot restore frames).

`.github/workflows/nightly.yml` runs at 08:00 UTC and exits early without a
macOS runner when `main` already matches the latest published commit (dispatch
with `force: true` to rebuild the same commit for recovery). Every attempt gets
a unique tag and immutable asset URL:

```text
nightly-<build>-<run>-<attempt>
https://github.com/kenn-io/ghosthub-nightly/releases/download/<tag>/<dmg>
```

Nightly notes separate commit hashes from subjects with a regular space so
Sparkle's Markdown renderer does not collapse tabs.

### Check a missing nightly

```sh
gh release view --repo kenn-io/ghosthub-nightly
gh run list --repo kenn-io/ghosthub --workflow nightly.yml --limit 5
```

Compare the release's source commit with `main`. Inspect any failed job and
check `channel.json` and `appcast.xml` under the latest release. To trigger a
fresh nightly, dispatch `nightly.yml` from `main` with `force: false` (use
`force: true` only to rebuild the same source). Never alter stable tags or
feeds to fix nightly.

### Publication, retention, and secrets

Publication verifies artifacts, appcast, and checksums, creates a draft with
the immutable DMG, its checksum, `SHA256SUMS`, `appcast.xml`, `channel.json`,
and `Ghosthub_Nightly_latest_macos_arm64.dmg`, revalidates the manifest, runs
retention (keeping all attempts of the current build plus the 29 highest prior
builds, ignoring drafts/prereleases/non-nightly tags), and publishes as latest
in one atomic transition (deleting the draft/tag on earlier failure).
Eligibility validates both manifest and appcast (treating broken feeds as
repairable) and fingerprints the prior manifest; publication rejects lower
builds, conflicting commits, or fingerprint drift so out-of-order retries
cannot roll the channel back.

Configure the `nightly-signing` environment (`main`-only, no required
reviewers) with environment secrets only:

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

Non-secret environment variables:

| Variable | Value |
| --- | --- |
| `NIGHTLY_SPARKLE_PUBLIC_ED_KEY` | Public key matching the nightly private seed |
| `NIGHTLY_RELEASE_APP_CLIENT_ID` | Client ID for the `kenn-dist-update-bot` GitHub App |

`kenn-dist-update-bot` is installed only on `kenn-io/ghosthub-nightly` (where
GitHub Actions stays disabled) and mints short-lived `contents: write` tokens
that cannot modify `kenn-io/ghosthub`. Because both channels share Kenn
Software's Apple Developer ID, this publication boundary is what isolates
stable users from unattended nightly credentials, with separate Sparkle keys as
defense in depth.

### Enrolling in and leaving nightly

Before enrolling, quit Ghosthub and back up shared state:

- `~/.ghosthub/` (or resolved state dir);
- `~/.config/ghosthub/` (or target selected by `init.toml` / env overrides);
- `defaults export com.ghosthub Ghosthub-preferences.plist`.

Because manual enrollment bypasses Sparkle, verify Gatekeeper acceptance and
pin Team ID `2YMZH84KR8` on both the DMG (before mounting) and the app:

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

Confirm **Ghosthub Nightly**, date, and revision in About. To leave nightly,
quit Ghosthub and reinstall the latest stable DMG from ghosthub.ai (restore
backed-up state and `defaults import com.ghosthub Ghosthub-preferences.plist`
only if state changed incompatibly). Compromise of the nightly Sparkle key or
bot key is a nightly incident; compromise of the shared Apple identity affects
both channels.

## Local packaging

Debug and release bundles automatically build the pinned local kwt binary and
six-target remote matrix. Override locally only when testing a separate build:

```bash
make release-app \
  KWT_BINARY_PATH=/absolute/path/to/kwt \
  KWT_VERSION=development \
  KWT_SOURCE_REVISION=local
```

`KWT_BINARY_PATH` overrides only the local helper; set `KWT_VARIANTS_DIR` only
to supply a prebuilt six-target matrix (validated for format, architecture, and
`KWT_REF`, never modified). Local stable builds embed `git describe` in
`GhosthubDevelopmentVersion` so About and telemetry report `X.Y.Z-N-gHASH`
(only release CI sets `OFFICIAL_RELEASE=1`). `tools/build_release_dmg.sh`
forwards kwt overrides only when nonempty.

Unsigned local DMG:

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

Local signed appcast (load the private seed from 1Password in real operations,
never from shell history):

```bash
SPARKLE_PUBLIC_ED_KEY='<reviewed public key>' \
SPARKLE_ED_PRIVATE_KEY='<temporary private seed>' \
make release-appcast
```

Outputs land in `dist/release/`. `tools/build_release_dmg.sh` signs from the
inside out (Sparkle nested helpers/framework, local kwt and Darwin remote kwt
variants, then the app with `Resources/Ghosthub.entitlements` kept in sync with
`Info.plist`); never replace this with `codesign --deep`. SwiftPM staging
copies only `GRDB_GRDB.bundle` (including its privacy manifest) into
`Contents/Resources` and never puts symlinks at the `.app` root. `make
debug-app` adds the library-validation exception only to its temporary ad-hoc
signature so macOS loads Sparkle without a Team ID; Developer ID signatures
always retain library validation.

Update this playbook whenever release packaging, signing, notarization, the
embedded kwt policy, or `.github/workflows/release.yml` changes.
