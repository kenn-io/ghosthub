# Homebrew Publication Design

## Context

Ghosthub is a signed native macOS application distributed as an Apple Silicon
DMG. It belongs in Homebrew as a cask, not as a source-built formula.

The long-term user experience is:

```sh
brew install ghosthub
```

Ghosthub is not yet eligible for the official `Homebrew/homebrew-cask`
repository. On 2026-08-05, the canonical repository was 14 days old and had 14
stars, 3 forks, and 1 watcher. Homebrew normally requires an owner-submitted
project to be at least 30 days old and to have 225 stars, 90 forks, or 90
watchers. Until those acceptance criteria are met, Ghosthub will publish from
the existing `kenn-io/homebrew-tap` repository.

The interim one-command install is:

```sh
brew install kenn-io/tap/ghosthub
```

After a user runs `brew tap kenn-io/tap`, the shorter `brew install ghosthub`
also resolves through the tap.

## Goals

- Publish the current signed Ghosthub application through
  `kenn-io/homebrew-tap` as a cask.
- Automate stable-release cask updates through tested pull requests in the tap.
- Make notarization a mandatory, fail-closed publication invariant.
- Make the Homebrew command the primary install action on ghosthub.ai while
  retaining the direct DMG download.
- Keep the cask portable so it can later be submitted to
  `Homebrew/homebrew-cask` with minimal changes.

## Non-goals

- Do not add Homebrew credentials or cross-repository dispatches to Ghosthub's
  protected release workflow.
- Do not change Ghosthub's signing, notarization, packaging, or Sparkle update
  behavior.
- Do not automate an official Homebrew submission before Ghosthub is eligible.
- Do not publish or install an unnotarized fallback under any circumstances.
- Do not add Intel support; Ghosthub currently targets Apple Silicon only.

## Cask

`kenn-io/homebrew-tap` will add `Casks/ghosthub.rb`. The cask will declare:

- the stable semantic version;
- the immutable versioned GitHub release DMG URL;
- the SHA-256 of the exact DMG bytes;
- Ghosthub's canonical name, description, and homepage;
- GitHub latest-release livecheck behavior;
- `auto_updates true`, preserving Ghosthub's existing Sparkle updater;
- Apple Silicon and macOS 26 or newer requirements;
- `Ghosthub.app` as the installed artifact; and
- optional `zap` cleanup limited to Ghosthub-owned mutable state, configuration,
  preferences, caches, and saved application state.

Ordinary `brew uninstall` removes only the application. User data is removed
only when the user explicitly requests `brew uninstall --zap`.

The cask will never bypass quarantine or Gatekeeper. Its checksum pins
Homebrew to the same bytes that pass the notarization gate.

## Notarization Invariant

Every cask version must pass all of the following checks before an initial
publication or automated update pull request can be created:

1. Download the exact versioned GitHub release DMG.
2. Recompute SHA-256 and require it to match the digest reported by GitHub's
   release API.
3. Run `xcrun stapler validate` on the DMG and require a valid stapled ticket.
4. Run Gatekeeper's primary-signature assessment on the DMG and require an
   accepted `Notarized Developer ID` result.
5. Mount the DMG read-only and deeply verify `Ghosthub.app` with `codesign`.
6. Run Gatekeeper's executable assessment on the app and require an accepted
   `Notarized Developer ID` result.
7. Require bundle identifier `com.ghosthub` and Developer ID Team Identifier
   `2YMZH84KR8`.
8. Run the Homebrew cask checks and installation cycle against that same
   checksum-pinned artifact.

Any missing ticket, rejected assessment, wrong signing identity, checksum
mismatch, malformed release metadata, or failed Homebrew check stops the
workflow before a cask change is proposed or published. The tap continues to
serve the last verified notarized version.

The published v0.6.0 DMG has already been checked against this contract. Its
SHA-256 is
`1306e0ad875cf62e334f1ffafcd04cb6794193c6d83cb78567514dbb1754949c`,
and both the DMG and embedded app are accepted by Gatekeeper as Notarized
Developer ID artifacts.

## Tap Automation

The tap will use a cask-specific updater rather than coupling cask behavior to
its existing formula updater.

An hourly and manually dispatchable workflow will:

1. Read the latest stable `kenn-io/ghosthub` GitHub release.
2. Validate an `X.Y.Z` version and refuse drafts, prereleases, downgrades, or
   malformed tags.
3. Require exactly the expected
   `Ghosthub_X.Y.Z_macos_arm64.dmg` asset at the canonical versioned GitHub URL.
4. Require a valid SHA-256 release digest.
5. Skip without changes when the cask is already current.
6. Run the artifact, staple, Gatekeeper, signature, and identity checks on an
   Apple Silicon macOS 26 runner.
7. Regenerate the cask deterministically and run Homebrew validation against
   the checksum-pinned artifact.
8. Upload the validated cask patch and open a pull request from a dedicated
   automation branch.

The workflow will not write directly to `main`. A failed API request, download,
validation, or installation produces no pull request. The updater uses only
the tap repository's scoped `GITHUB_TOKEN`; Ghosthub's release environment
does not receive a cross-repository token.

The updater will have focused fixture-based tests for release selection,
version comparison, asset URL and name checks, SHA-256 handling, and failure
behavior. Tests will exercise meaningful orchestration contracts rather than
asserting source text.

## Website and Documentation

The website will use a reusable install-command component backed by one shared
configuration constant. The selected command-first hero treatment is:

- a tight CLI bubble containing
  `$ brew install kenn-io/tap/ghosthub` as the primary action;
- a copy control that supports pointer and keyboard activation;
- short, accessible success feedback after copying; and
- a smaller direct-DMG fallback immediately below the bubble.

The Guide's introductory install area will reuse the component. `README.md`
will show the same Homebrew command in plain Markdown, followed by the manual
DMG fallback. The tap README will list Ghosthub under available casks.
`docs/release.md` will document the downstream tap update and notarization
gate.

When the official cask is accepted, the shared website constant and docs will
change to `brew install ghosthub`; the visual component and copy behavior will
not need redesign.

No product screenshot refresh is required. Ghosthub's app UI and the visuals
inside the published screenshots do not change.

## Validation

Tap validation will include:

- updater fixture tests and Ruby syntax checks;
- `brew style` for the cask;
- strict and online cask audit where appropriate;
- the complete notarization invariant;
- `brew install --cask kenn-io/tap/ghosthub` on Apple Silicon macOS 26;
- verification of the installed app bundle and signing identity; and
- `brew uninstall --cask kenn-io/tap/ghosthub`.

Ghosthub website validation will include its existing type-check, lint, unit
test, and production build commands. Browser checks at desktop and mobile
widths will cover command wrapping, copy feedback, keyboard operation, and the
DMG fallback.

## Official Homebrew Transition

Official publication remains a separately tracked action. Once Ghosthub meets
Homebrew's age and notability requirements:

1. Search open and closed Homebrew cask pull requests again for conflicts or
   prior decisions.
2. Re-run the current official acceptance policy review.
3. Port the tap cask to a fresh `Homebrew/homebrew-cask` branch.
4. Run Homebrew's current new-cask style, strict online audit,
   install/uninstall, and notarization checks.
5. Submit one concise pull request and disclose AI assistance as Homebrew
   requires.
6. After acceptance, change public installation instructions to
   `brew install ghosthub` while retaining the tap only as needed for orderly
   transition.

Meeting numerical thresholds does not guarantee acceptance; Homebrew
maintainers retain discretion. Until acceptance, public documentation must not
imply that Ghosthub is in the official cask repository.
