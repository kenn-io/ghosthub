# Ghosthub Homebrew Tap Publication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish only notarized Ghosthub releases through `kenn-io/homebrew-tap` and automatically prepare tested cask update pull requests.

**Architecture:** A pure Ruby release model validates GitHub metadata and renders the cask. An hourly Linux job performs the cheap release/version check; only a newly discovered version starts Apple Silicon macOS 26 verification, Homebrew installation, and patch generation. The workflow-scoped `GITHUB_TOKEN` opens a PR only after those checks pass, and the pre-PR macOS job is the authoritative test evidence.

**Tech Stack:** Homebrew Cask DSL, Ruby 3.4.5 and Minitest, Bash, Apple `stapler`/`spctl`/`codesign`, GitHub Actions

## Global Constraints

- Work in `kenn-io/homebrew-tap`, not in the Ghosthub source checkout.
- Package only `Ghosthub_X.Y.Z_macos_arm64.dmg` from stable `kenn-io/ghosthub` GitHub releases.
- Require Apple Silicon and macOS 26 (`:tahoe`) or newer.
- Require bundle identifier `com.ghosthub` and Team Identifier `2YMZH84KR8`.
- A cask version may be proposed only after the DMG and embedded app both pass Gatekeeper as `Notarized Developer ID` artifacts.
- Never disable quarantine, skip Gatekeeper, use an unsigned fallback, or accept a missing release digest.
- Preserve Sparkle and declare `auto_updates true`.
- Use only the repository-scoped `GITHUB_TOKEN`; do not add a PAT, GitHub App secret, or Ghosthub cross-repository credential.
- Treat pre-PR validation as authoritative because workflow-created PR checks do not run automatically without maintainer approval.
- Do not configure a required status check that leaves automation PRs waiting for their own PR-triggered workflow.
- Invoke `kenn:commit` before every commit. Do not amend commits.
- Do not push or open a pull request unless the active user request explicitly authorizes it.

## File Structure

- Create `Casks/ghosthub.rb`: portable Homebrew cask definition.
- Create `scripts/ghosthub_cask.rb`: pure release validation, version comparison, metadata serialization, cask parsing, and rendering.
- Create `scripts/update-ghosthub-cask.rb`: CLI for `current`, `check`, and `render` operations.
- Create `scripts/verify-ghosthub-app.sh`: reusable app signature, Gatekeeper, bundle-ID, and Team-ID verification.
- Create `scripts/verify-ghosthub-release.sh`: exact download, checksum, staple, DMG Gatekeeper, read-only mount, and embedded-app verification.
- Create `test/ghosthub_cask_test.rb`: deterministic release-model tests using Minitest.
- Create `.github/workflows/cask-ci.yml`: cask checks for human PRs and pushes.
- Create `.github/workflows/update-casks.yml`: cheap Linux polling, conditional macOS verification, and PR creation.
- Modify `README.md`: list Ghosthub as an available cask and document both tap install forms.

---

### Task 1: Build the release model and deterministic cask renderer

**Files:**
- Create: `scripts/ghosthub_cask.rb`
- Create: `scripts/update-ghosthub-cask.rb`
- Create: `test/ghosthub_cask_test.rb`

**Interfaces:**
- Produces: `GhosthubCask::Release = Data.define(:version, :tag_name, :filename, :url, :sha256)`.
- Produces: `GhosthubCask.parse_release(payload) -> GhosthubCask::Release`.
- Produces: `GhosthubCask.parse_current_cask(text) -> GhosthubCask::Release`.
- Produces: `GhosthubCask.newer?(candidate, current) -> true | false`.
- Produces: `GhosthubCask.dump_metadata(release) -> String` and `GhosthubCask.load_metadata(text) -> GhosthubCask::Release`.
- Produces: `GhosthubCask.render(release) -> String`.
- Produces CLI commands `current OUTPUT`, `check OUTPUT`, and `render INPUT`.

- [ ] **Step 1: Write release-validation tests**

Create `test/ghosthub_cask_test.rb` with Minitest cases that build hashes in memory. Cover:

```ruby
def release_payload(version: "0.6.0", digest: VALID_SHA, draft: false, prerelease: false)
  tag = "v#{version}"
  filename = "Ghosthub_#{version}_macos_arm64.dmg"
  {
    "tag_name" => tag,
    "draft" => draft,
    "prerelease" => prerelease,
    "assets" => [{
      "name" => filename,
      "browser_download_url" => "https://github.com/kenn-io/ghosthub/releases/download/#{tag}/#{filename}",
      "digest" => "sha256:#{digest}",
    }],
  }
end
```

Assert that a valid stable payload produces the exact version, tag, filename,
URL, and lowercase SHA-256. Assert that draft and prerelease payloads, tags
other than `vX.Y.Z`, missing or malformed digests, missing expected assets,
duplicate expected assets, non-GitHub hosts, query strings, and mismatched URL
paths raise `GhosthubCask::ReleaseError` with a specific diagnostic.

- [ ] **Step 2: Run the tests and confirm the release model is absent**

Run:

```bash
mise exec --locked -- ruby -Itest test/ghosthub_cask_test.rb
```

Expected: FAIL because `scripts/ghosthub_cask.rb` does not exist.

- [ ] **Step 3: Implement strict release parsing**

Create `scripts/ghosthub_cask.rb` with these constants and types:

```ruby
module GhosthubCask
  REPOSITORY = "kenn-io/ghosthub"
  CASK_PATH = "Casks/ghosthub.rb"
  RELEASE_API = "https://api.github.com/repos/#{REPOSITORY}/releases/latest"
  TAG_PATTERN = /\Av(\d+)\.(\d+)\.(\d+)\z/
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/
  BUNDLE_ID = "com.ghosthub"
  TEAM_ID = "2YMZH84KR8"

  class ReleaseError < StandardError; end

  Release = Data.define(:version, :tag_name, :filename, :url, :sha256)
end
```

`parse_release` must reject draft/prerelease releases, require one exact asset,
require a `sha256:` digest, validate the canonical HTTPS GitHub URL without a
query or fragment, and return an immutable `Release`.

- [ ] **Step 4: Run the release-validation tests**

Run:

```bash
mise exec --locked -- ruby -Itest test/ghosthub_cask_test.rb
```

Expected: the release-validation cases PASS.

- [ ] **Step 5: Add version, metadata, and renderer tests**

Add tests asserting:

```ruby
assert GhosthubCask.newer?("0.6.1", "0.6.0")
refute GhosthubCask.newer?("0.6.0", "0.6.0")
refute GhosthubCask.newer?("0.5.9", "0.6.0")
assert_equal release, GhosthubCask.load_metadata(GhosthubCask.dump_metadata(release))
assert_equal release, GhosthubCask.parse_current_cask(GhosthubCask.render(release))
```

Also require `load_metadata` to revalidate every field rather than trusting the
artifact passed between workflow jobs.

- [ ] **Step 6: Run the tests and confirm the new functions are absent**

Run:

```bash
mise exec --locked -- ruby -Itest test/ghosthub_cask_test.rb
```

Expected: FAIL with missing `newer?`, metadata, or renderer methods.

- [ ] **Step 7: Implement version comparison, metadata round-trip, and rendering**

Render exactly this cask shape from a validated `Release`:

```ruby
cask "ghosthub" do
  version "0.6.0"
  sha256 "1306e0ad875cf62e334f1ffafcd04cb6794193c6d83cb78567514dbb1754949c"

  url "https://github.com/kenn-io/ghosthub/releases/download/v#{version}/Ghosthub_#{version}_macos_arm64.dmg",
      verified: "github.com/kenn-io/ghosthub/"
  name "Ghosthub"
  desc "Native terminal for local and remote tmux fleets"
  homepage "https://ghosthub.ai/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Ghosthub.app"

  zap trash: [
    "~/.config/ghosthub",
    "~/.ghosthub",
    "~/Library/Caches/com.ghosthub",
    "~/Library/HTTPStorages/com.ghosthub",
    "~/Library/Preferences/com.ghosthub.plist",
    "~/Library/Saved Application State/com.ghosthub.savedState",
    "~/Library/WebKit/com.ghosthub",
  ]
end
```

Use numeric `X.Y.Z` segment comparison. `parse_current_cask` must read only the
single `version` and `sha256` string stanzas, validate them, and reconstruct the
canonical tag, filename, and URL.

- [ ] **Step 8: Implement the CLI without network access in pure operations**

Create `scripts/update-ghosthub-cask.rb` with:

```text
update-ghosthub-cask.rb current OUTPUT
update-ghosthub-cask.rb check OUTPUT
update-ghosthub-cask.rb render INPUT
```

`current` serializes the committed cask. `check` fetches `RELEASE_API` with the
GitHub API headers and optional bearer `GITHUB_TOKEN`, validates the response,
and writes `OUTPUT` only when the release is newer. `render` revalidates
`INPUT`, refuses a downgrade, and writes `Casks/ghosthub.rb`. All failures exit
nonzero with one actionable stderr diagnostic.

- [ ] **Step 9: Run unit and syntax checks**

Run:

```bash
mise exec --locked -- ruby -Itest test/ghosthub_cask_test.rb
mise exec --locked -- ruby -c scripts/ghosthub_cask.rb
mise exec --locked -- ruby -c scripts/update-ghosthub-cask.rb
```

Expected: all tests PASS and both syntax checks print `Syntax OK`.

- [ ] **Step 10: Commit the release model**

Invoke `kenn:commit`, then commit only the three task files with a rationale
explaining that untrusted release metadata is normalized before any macOS
runner or cask mutation is allowed.

---

### Task 2: Publish the initial cask behind mandatory Apple verification

**Files:**
- Create: `Casks/ghosthub.rb`
- Create: `scripts/verify-ghosthub-app.sh`
- Create: `scripts/verify-ghosthub-release.sh`

**Interfaces:**
- Consumes: `scripts/update-ghosthub-cask.rb render INPUT` and `current OUTPUT` from Task 1.
- Produces: `scripts/verify-ghosthub-app.sh APP_PATH`.
- Produces: `scripts/verify-ghosthub-release.sh METADATA_PATH`.

- [ ] **Step 1: Render and inspect the initial cask**

Create metadata for v0.6.0 using the verified SHA-256, run the renderer, and
confirm that parsing the generated cask returns the same `Release`:

```bash
mise exec --locked -- ruby -I. -rscripts/ghosthub_cask -e '
  release = GhosthubCask::Release.new(
    version: "0.6.0",
    tag_name: "v0.6.0",
    filename: "Ghosthub_0.6.0_macos_arm64.dmg",
    url: "https://github.com/kenn-io/ghosthub/releases/download/v0.6.0/Ghosthub_0.6.0_macos_arm64.dmg",
    sha256: "1306e0ad875cf62e334f1ffafcd04cb6794193c6d83cb78567514dbb1754949c",
  )
  File.write("ghosthub-release.json", GhosthubCask.dump_metadata(release))
'
mise exec --locked -- ruby scripts/update-ghosthub-cask.rb render ghosthub-release.json
mise exec --locked -- ruby scripts/update-ghosthub-cask.rb current current-release.json
cmp ghosthub-release.json current-release.json
```

Delete the two root-level metadata scratch files after comparison; do not
commit them.

- [ ] **Step 2: Implement reusable app verification**

Create `scripts/verify-ghosthub-app.sh` with `set -euo pipefail`. It must:

```bash
codesign --verify --deep --strict --verbose=4 "$app_path"
gatekeeper_output="$(spctl --assess --type execute --verbose=4 "$app_path" 2>&1)"
[[ "$gatekeeper_output" == *"source=Notarized Developer ID"* ]]
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
[[ "$bundle_id" == "com.ghosthub" ]]
signature_output="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
[[ "$signature_output" == *"TeamIdentifier=2YMZH84KR8"* ]]
```

Reject a missing app path, print the Apple verification output on failure, and
never weaken the `codesign` or `spctl` commands.

- [ ] **Step 3: Implement exact release verification**

Create `scripts/verify-ghosthub-release.sh` with `set -euo pipefail`. It must:

- require `uname -m` to be `arm64` and macOS major version at least 26;
- load and revalidate metadata through `GhosthubCask.load_metadata`;
- download with `curl --fail --silent --show-error --location` into a
  `mktemp -d` directory;
- compare `shasum -a 256` to the metadata SHA;
- require `xcrun stapler validate` to succeed;
- require `spctl --assess --type open --context context:primary-signature`
  to report `source=Notarized Developer ID`;
- mount with `hdiutil attach -nobrowse -readonly -mountpoint`;
- require exactly `Ghosthub.app` in the mounted root;
- invoke `verify-ghosthub-app.sh` on that app; and
- detach the mount and clean only the script-created temporary directory in an
  `EXIT` trap.

- [ ] **Step 4: Run the live v0.6.0 notarization contract**

Run on Apple Silicon macOS 26:

```bash
mise exec --locked -- ruby scripts/update-ghosthub-cask.rb current current-release.json
scripts/verify-ghosthub-release.sh current-release.json
```

Expected: checksum match; `stapler` succeeds; DMG and app Gatekeeper outputs
contain `source=Notarized Developer ID`; app identity is `com.ghosthub` and
Team ID `2YMZH84KR8`. Remove `current-release.json` after the check.

- [ ] **Step 5: Run Homebrew static checks against the new cask**

From a checkout tapped as `kenn-io/tap`, run:

```bash
brew style --cask kenn-io/tap/ghosthub
brew audit --strict --online --cask kenn-io/tap/ghosthub
brew livecheck --cask kenn-io/tap/ghosthub
```

Expected: style and audit succeed; livecheck reports v0.6.0 as current.

- [ ] **Step 6: Commit the notarized cask boundary**

Invoke `kenn:commit`, then commit the cask and both verification scripts. The
commit body must explain that a valid checksum is necessary but insufficient:
the exact bytes must also carry a valid Apple ticket and the expected signing
identity.

---

### Task 3: Add conditional update automation and cask CI

**Files:**
- Create: `.github/workflows/cask-ci.yml`
- Create: `.github/workflows/update-casks.yml`
- Modify: `.github/workflows/ci.yml:47-48`

**Interfaces:**
- Consumes: all Task 1 and Task 2 commands.
- Produces: artifact `ghosthub-release-metadata` containing `ghosthub-release.json`.
- Produces: artifact `ghosthub-cask-patch` containing `ghosthub-cask.patch`.
- Produces: automation branch `automation/update-ghosthub-cask` and PR title `Update Ghosthub cask to ${{ needs.validate.outputs.version }}`.

- [ ] **Step 1: Extend existing CI syntax coverage**

Add syntax and unit commands to the existing `homebrew` job without making its
formula install loop aware of casks:

```bash
mise exec --locked -- ruby -c scripts/ghosthub_cask.rb
mise exec --locked -- ruby -c scripts/update-ghosthub-cask.rb
mise exec --locked -- ruby -Itest test/ghosthub_cask_test.rb
```

Keep formula style, audit, install, and test behavior unchanged on both Linux
and macOS.

- [ ] **Step 2: Create path-scoped cask CI**

Create `.github/workflows/cask-ci.yml` triggered by `pull_request`, pushes to
`main`, and `workflow_dispatch`. Apply path filters for:

```yaml
- 'Casks/ghosthub.rb'
- 'scripts/ghosthub_cask.rb'
- 'scripts/update-ghosthub-cask.rb'
- 'scripts/verify-ghosthub-app.sh'
- 'scripts/verify-ghosthub-release.sh'
- 'test/ghosthub_cask_test.rb'
- '.github/workflows/cask-ci.yml'
- '.github/workflows/update-casks.yml'
```

The single job runs on `macos-26`, verifies `uname -m == arm64`, checks out
without persisted credentials, sets up pinned mise and Homebrew actions using
the same action SHAs already present in the tap, and verifies that
`brew --repo kenn-io/tap` resolves to `GITHUB_WORKSPACE`.

- [ ] **Step 3: Add the full cask-CI command sequence**

Run, in order:

```bash
mise exec --locked -- ruby -Itest test/ghosthub_cask_test.rb
mise exec --locked -- ruby scripts/update-ghosthub-cask.rb current ghosthub-release.json
scripts/verify-ghosthub-release.sh ghosthub-release.json
brew style --cask kenn-io/tap/ghosthub
brew audit --strict --online --cask kenn-io/tap/ghosthub
brew livecheck --cask kenn-io/tap/ghosthub
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask kenn-io/tap/ghosthub
scripts/verify-ghosthub-app.sh /Applications/Ghosthub.app
HOMEBREW_NO_INSTALL_FROM_API=1 brew uninstall --cask kenn-io/tap/ghosthub
```

Use an `always()` cleanup step to uninstall Ghosthub if an earlier assertion
fails. Do not use `--no-quarantine`.

- [ ] **Step 4: Create the cheap Linux polling job**

In `.github/workflows/update-casks.yml`, trigger hourly with cron
`17 * * * *` and via `workflow_dispatch`. The `check` job runs on
`ubuntu-latest`, requires `refs/heads/main`, uses `contents: read`, and:

```bash
mise exec --locked -- ruby -Itest test/ghosthub_cask_test.rb
mise exec --locked -- ruby scripts/update-ghosthub-cask.rb check ghosthub-release.json
```

Set a `changed` job output from `test -f ghosthub-release.json`. Upload the
metadata artifact only when changed. This job must not set up Homebrew or start
a macOS runner.

- [ ] **Step 5: Create the conditional macOS validation job**

The `validate` job must have:

```yaml
needs: check
if: needs.check.outputs.changed == 'true'
runs-on: macos-26
permissions:
  contents: read
```

After checkout, pinned mise/Homebrew setup, and metadata artifact download,
run the complete Task 2 release verification. Only after it succeeds, render
the cask, run style/audit/livecheck/install/installed-app verification/uninstall,
and create `ghosthub-cask.patch` with:

```bash
git diff --binary -- Casks/ghosthub.rb > ghosthub-cask.patch
test -s ghosthub-cask.patch
```

Upload that patch as `ghosthub-cask-patch`.

Declare a `version` job output. Populate it from a step with `id: release`:

```bash
version="$(mise exec --locked -- ruby -I. -rscripts/ghosthub_cask -rjson -e \
  'puts GhosthubCask.load_metadata(File.read("ghosthub-release.json")).version')"
echo "version=$version" >> "$GITHUB_OUTPUT"
```

and map it at job level with
`version: ${{ steps.release.outputs.version }}`.

- [ ] **Step 6: Create the PR job with pre-PR evidence**

The Ubuntu `create-pull-request` job needs `validate`, downloads and applies the
patch, reads the new cask version with the Ruby model, and uses the already
pinned `peter-evans/create-pull-request` action with:

```yaml
token: ${{ github.token }}
branch: automation/update-ghosthub-cask
delete-branch: true
title: "Update Ghosthub cask to ${{ needs.validate.outputs.version }}"
commit-message: "Update Ghosthub cask to ${{ needs.validate.outputs.version }}"
```

The concise PR body must say that the exact SHA-pinned DMG passed staple,
Gatekeeper, signing-identity, Homebrew audit, install, installed-app, and
uninstall checks in the updater run. Add a workflow comment explaining that
normal PR CI may wait for approval because this PR uses `GITHUB_TOKEN`; do not
add a PAT/App workaround.

- [ ] **Step 7: Validate both workflows locally**

Run:

```bash
mise exec --locked -- ruby -Itest test/ghosthub_cask_test.rb
mise exec --locked -- ruby -c scripts/ghosthub_cask.rb
mise exec --locked -- ruby -c scripts/update-ghosthub-cask.rb
actionlint .github/workflows/ci.yml .github/workflows/cask-ci.yml .github/workflows/update-casks.yml
brew style --cask kenn-io/tap/ghosthub
brew audit --strict --online --cask kenn-io/tap/ghosthub
```

Expected: all commands succeed. If `actionlint` is unavailable, install it with
Homebrew and rerun; do not substitute a YAML text test.

- [ ] **Step 8: Confirm branch-protection posture without changing it**

Run:

```bash
gh api repos/kenn-io/homebrew-tap/branches/main/protection
```

Expected for the current repository: HTTP 404 because `main` is unprotected.
If protection has been added since planning, inspect required checks and stop
before publication if any depend on automatically started PR CI. Do not mutate
repository rules without explicit authorization.

- [ ] **Step 9: Commit the automation**

Invoke `kenn:commit`, then commit the workflow and CI changes. The rationale
must call out both cost control (Linux polling) and trust control (conditional
macOS verification before PR creation).

---

### Task 4: Document and exercise the tap install path

**Files:**
- Modify: `README.md:1-56`

**Interfaces:**
- Consumes: published cask token `kenn-io/tap/ghosthub`.
- Produces: user-facing tap installation instructions.

- [ ] **Step 1: Update tap scope and add Ghosthub**

Change the introduction from “Custom Homebrew formulas” to “Custom Homebrew
formulae and casks.” Add an `Available Casks` section before the formulae with:

```bash
brew install kenn-io/tap/ghosthub
```

and the already-tapped form:

```bash
brew tap kenn-io/tap
brew install ghosthub
```

Describe Ghosthub as a native macOS terminal for local and remote tmux fleets,
state Apple Silicon/macOS 26 requirements, and link to `https://ghosthub.ai/`.

- [ ] **Step 2: Exercise installation from the local tap checkout**

Run on Apple Silicon macOS 26:

```bash
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask kenn-io/tap/ghosthub
scripts/verify-ghosthub-app.sh /Applications/Ghosthub.app
HOMEBREW_NO_INSTALL_FROM_API=1 brew uninstall --cask kenn-io/tap/ghosthub
```

Expected: install and both Apple assessments succeed; uninstall removes the
app without deleting `~/.ghosthub` or `~/.config/ghosthub`.

- [ ] **Step 3: Run the complete tap verification set**

Run the Task 3 unit, syntax, actionlint, style, audit, livecheck, notarization,
install, installed-app verification, and uninstall commands once more from a
clean working tree.

- [ ] **Step 4: Commit the tap documentation**

Invoke `kenn:commit`, then commit the README update with the user need in the
message body. Confirm `git status --short --branch` is clean afterward.

- [ ] **Step 5: Publication handoff**

If the user has explicitly authorized pushing and opening the tap PR, push the
task branch and open one concise rationale-first PR. Otherwise report the local
commits, proposed branch name `ghosthub-cask`, and the validation evidence
without changing GitHub state.
