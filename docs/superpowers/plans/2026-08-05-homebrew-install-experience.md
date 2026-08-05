# Ghosthub Homebrew Install Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Kenn Homebrew tap the primary Ghosthub installation path across ghosthub.ai and repository documentation while preserving a direct notarized-DMG fallback.

**Architecture:** A reusable Astro component reads one shared install-command constant, renders the selected command-first CLI bubble, and delegates clipboard behavior to a small tested TypeScript helper. The landing-page hero and Guide reuse the component; release and README documentation explain the downstream tap automation without changing Ghosthub's protected release workflow.

**Tech Stack:** Astro 7, TypeScript 5.9, Vitest, pnpm 11, browser-based visual/accessibility verification, Markdown documentation

## Global Constraints

- Work in the Ghosthub `homebrew-release` task branch, never directly on `main`.
- Display exactly `brew install kenn-io/tap/ghosthub` until the official Homebrew cask is accepted.
- Keep the direct versioned notarized DMG available as a secondary fallback.
- The Homebrew command is the primary hero action; preserve the approved tight CLI-bubble treatment.
- Copy interaction must work with pointer and keyboard activation and provide visible `aria-live` feedback.
- Do not add clipboard compatibility shims or deprecated `document.execCommand` fallbacks.
- Do not change Ghosthub's release workflow, signing, notarization, Sparkle behavior, or release artifact names.
- Update the website Guide and README because installation is user-facing behavior.
- Do not refresh product screenshots; the app visuals inside them are unchanged.
- Do not run `make site-deploy`, push, or open a pull request without explicit user authorization.
- Use `sites:sites-building` for the website implementation and browser controls for visual QA.
- Invoke `kenn:test-scope-discipline` before adding tests and `kenn:commit` before every commit.
- Remove all `docs/superpowers/specs/` and `docs/superpowers/plans/` artifacts from the branch before any push or pull request.

## File Structure

- Modify `website/src/config.ts`: add the single public Homebrew command constant.
- Create `website/src/lib/install.ts`: clipboard-result helper with no DOM dependency.
- Create `website/src/lib/install.test.ts`: focused success/failure tests for exact command copying.
- Create `website/src/components/InstallCommand.astro`: accessible CLI bubble, copy button, status region, and DMG fallback.
- Modify `website/src/scripts/site.ts`: wire every install component to the clipboard helper.
- Modify `website/src/components/Hero.astro`: replace the existing action buttons with the command-first component.
- Modify `website/src/pages/guide.astro`: replace the opening download button with the same component.
- Modify `README.md`: make Homebrew primary and direct DMG secondary.
- Modify `docs/release.md`: document downstream cask polling, mandatory notarization checks, and PR-token behavior.

---

### Task 1: Build and integrate the command-first install component

**Files:**
- Modify: `website/src/config.ts:1-4`
- Create: `website/src/lib/install.ts`
- Create: `website/src/lib/install.test.ts`
- Create: `website/src/components/InstallCommand.astro`
- Modify: `website/src/scripts/site.ts:1-118`
- Modify: `website/src/components/Hero.astro:1-215`
- Modify: `website/src/pages/guide.astro:1-60, 516-543`

**Interfaces:**
- Produces: `HOMEBREW_INSTALL_COMMAND = 'brew install kenn-io/tap/ghosthub'` from `website/src/config.ts`.
- Produces: `copyInstallCommand(writeText, command) -> Promise<'copied' | 'failed'>`.
- Produces DOM contract: `[data-install-command]`, `[data-install-copy]`, and `[data-install-status]`.
- Consumes: existing `[data-download]` release-link enhancement in `site.ts`.

- [ ] **Step 1: Read the website-building skill and test-scope rules**

Read `sites:sites-building` and `kenn:test-scope-discipline` completely before
editing. Keep the test limited to Ghosthub's result contract; do not test the
browser's Clipboard API implementation or committed Astro source strings.

- [ ] **Step 2: Write clipboard-result tests**

Create `website/src/lib/install.test.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { copyInstallCommand } from './install';

describe('copyInstallCommand', () => {
  it('copies the exact command and reports success', async () => {
    const writeText = vi.fn(async () => undefined);
    const result = await copyInstallCommand(
      writeText,
      'brew install kenn-io/tap/ghosthub',
    );
    expect(writeText).toHaveBeenCalledWith('brew install kenn-io/tap/ghosthub');
    expect(result).toBe('copied');
  });

  it('reports failure when the browser rejects clipboard access', async () => {
    const writeText = vi.fn(async () => Promise.reject(new Error('denied')));
    await expect(
      copyInstallCommand(writeText, 'brew install kenn-io/tap/ghosthub'),
    ).resolves.toBe('failed');
  });
});
```

- [ ] **Step 3: Run the focused test and confirm the helper is absent**

Run from `website/`:

```bash
pnpm exec vitest run src/lib/install.test.ts
```

Expected: FAIL because `src/lib/install.ts` does not exist.

- [ ] **Step 4: Implement the minimal clipboard helper**

Create `website/src/lib/install.ts`:

```ts
export type CopyInstallResult = 'copied' | 'failed';

export async function copyInstallCommand(
  writeText: (value: string) => Promise<void>,
  command: string,
): Promise<CopyInstallResult> {
  try {
    await writeText(command);
    return 'copied';
  } catch {
    return 'failed';
  }
}
```

- [ ] **Step 5: Run the focused test and confirm it passes**

Run:

```bash
pnpm exec vitest run src/lib/install.test.ts
```

Expected: both cases PASS.

- [ ] **Step 6: Add the shared command and component markup**

Add to `website/src/config.ts`:

```ts
export const HOMEBREW_INSTALL_COMMAND = 'brew install kenn-io/tap/ghosthub';
```

Create `InstallCommand.astro` importing `HOMEBREW_INSTALL_COMMAND` and
`RELEASES_URL`. Render:

```astro
<div class="install-command" data-install-command data-command={HOMEBREW_INSTALL_COMMAND}>
  <div class="bubble">
    <span class="prompt" aria-hidden="true">$</span>
    <code>{HOMEBREW_INSTALL_COMMAND}</code>
    <button
      type="button"
      data-install-copy
      aria-label="Copy Homebrew install command"
      title="Copy Homebrew install command"
    >
      <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
        <rect x="5" y="5" width="8" height="8" rx="1"></rect>
        <path d="M3 11H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1h8a1 1 0 0 1 1 1v1"></path>
      </svg>
    </button>
  </div>
  <span class="status" data-install-status aria-live="polite"></span>
  <a class="download" data-download href={RELEASES_URL}>or download the DMG <span aria-hidden="true">→</span></a>
</div>
```

Style the root as a centered compact column. Style `.bubble` as the approved
dark raised pill with accent prompt, one-pixel border, nine-pixel radius,
JetBrains Mono, and a separated copy control. Keep it at intrinsic width with
`max-width: 100%`; allow the code segment to wrap on very narrow screens while
the copy button remains reachable. Give the copy button a visible hover state
and rely on the global `:focus-visible` outline. Reserve one line for `.status`
so success feedback does not move the hero.

- [ ] **Step 7: Wire clipboard behavior into the existing site entry point**

Import `copyInstallCommand` in `website/src/scripts/site.ts` and add:

```ts
function setupInstallCommands(): void {
  for (const root of document.querySelectorAll('[data-install-command]')) {
    if (!(root instanceof HTMLElement)) continue;
    const button = root.querySelector('[data-install-copy]');
    const status = root.querySelector('[data-install-status]');
    const command = root.dataset.command;
    if (!(button instanceof HTMLButtonElement) || !(status instanceof HTMLElement) || !command) continue;

    let resetTimer: number | undefined;

    button.addEventListener('click', async () => {
      const writeText = navigator.clipboard?.writeText.bind(navigator.clipboard);
      const result = writeText
        ? await copyInstallCommand(writeText, command)
        : 'failed';
      status.textContent = result === 'copied'
        ? 'Copied'
        : 'Copy failed — select the command to copy';
      window.clearTimeout(resetTimer);
      if (result === 'copied') {
        resetTimer = window.setTimeout(() => {
          status.textContent = '';
        }, 2_000);
      }
    });
  }
}
```

Call `setupInstallCommands()` beside `setupImageLightbox()`. The native button
supplies Enter/Space behavior; do not add manual keyboard listeners.

- [ ] **Step 8: Replace landing-page and Guide download CTAs**

In `Hero.astro`, import `InstallCommand`, replace `.actions` with:

```astro
<div class="install-action"><InstallCommand /></div>
```

Remove the old `.cta`, `.learn`, and `.actions` CSS. Animate
`.install-action` at the former action delay. The Guide remains reachable in
the sticky header.

In `guide.astro`, import `InstallCommand`, remove the now-unused
`RELEASES_URL` import, and replace the opening `.download` anchor with
`<InstallCommand />`. Remove `.download` from the combined `.download,
.finish a` selector while preserving `.finish a` styling.

- [ ] **Step 9: Run website checks**

From `website/`, run:

```bash
pnpm check
pnpm lint
pnpm test
pnpm build
```

Expected: all commands succeed using the real synced product assets in the
local production build.

- [ ] **Step 10: Perform browser visual and accessibility QA**

Start the site with:

```bash
pnpm dev -- --host 127.0.0.1
```

Using browser controls, inspect `/` and `/guide/` at 1440×900 and 390×844.
Confirm the command is primary, the DMG link is secondary, the bubble does not
overflow, the copy button is focusable, Enter and Space activate it, successful
copy announces `Copied`, denied clipboard access shows the failure text, and
the dynamic `[data-download]` link still resolves to the current DMG.

- [ ] **Step 11: Commit the install component**

Invoke `kenn:commit`, then commit the config, helper, test, component, site
script, hero, and Guide changes. The body should explain why a terminal-native
install command is primary while the DMG remains available.

---

### Task 2: Update repository and release documentation

**Files:**
- Modify: `README.md:92-115`
- Modify: `docs/release.md:261-303`

**Interfaces:**
- Consumes: tap token `kenn-io/tap/ghosthub` and the approved tap automation contract.
- Produces: public install instructions and maintainer release expectations.

- [ ] **Step 1: Make Homebrew the primary README install path**

Keep the existing requirements. Replace the numbered DMG-first instructions
with:

```sh
brew install kenn-io/tap/ghosthub
```

Then tell users to launch Ghosthub from Applications. Present the latest
notarized GitHub DMG and drag-to-Applications flow as the manual alternative.
Keep the separate `brew install tmux` prerequisite guidance unchanged.

- [ ] **Step 2: Document the downstream tap release flow**

Add a `### Homebrew tap` subsection under `docs/release.md` Publishing. State
that the tap's hourly Linux job only checks latest stable metadata and starts
Apple Silicon macOS 26 work only for a newer version. List the mandatory exact
checksum, staple, DMG Gatekeeper, deep app signature, app Gatekeeper, bundle
ID, Team ID, Homebrew audit, install, installed-app, and uninstall gates.

State explicitly that workflow-created PRs use the tap's `GITHUB_TOKEN`, so
their ordinary PR CI may wait for maintainer approval; the successful pre-PR
validation job is authoritative, and the design intentionally avoids a PAT or
separate GitHub App token.

- [ ] **Step 3: Run documentation and website verification**

Run from the repository root:

```bash
make docs-build
cd website
pnpm check
pnpm lint
pnpm test
pnpm build
```

Expected: all commands succeed. No Swift or release-packaging source changed,
so `make build` and terminal regression gates are not required for this task.

- [ ] **Step 4: Commit the documentation**

Invoke `kenn:commit`, then commit `README.md` and `docs/release.md` with a body
explaining the public install path and the fail-closed downstream publication
contract.

---

### Task 3: Track the official-cask follow-up and prepare a clean handoff

**Files:**
- Delete before any push: `docs/superpowers/specs/2026-08-05-homebrew-publication-design.md`
- Delete before any push: `docs/superpowers/plans/2026-08-05-homebrew-tap-publication.md`
- Delete before any push: `docs/superpowers/plans/2026-08-05-homebrew-install-experience.md`

**Interfaces:**
- Consumes: current kata issue `bwq4`.
- Produces: a separate kata issue for official `Homebrew/homebrew-cask` submission.

- [ ] **Step 1: Create the official-submission follow-up in kata**

Search first, then create only if no equivalent issue exists:

```bash
kata search "official Homebrew cask submission" --agent
kata create "Submit Ghosthub to the official Homebrew cask repository" \
  --body "When the canonical repository satisfies Homebrew's current age and author-submission notability criteria, re-check policy and prior PRs, port the verified tap cask, run the full new-cask and notarization suite, and submit one AI-disclosed PR to Homebrew/homebrew-cask. Do not imply official availability before acceptance." \
  --label area:infra \
  --label priority:p2 \
  --related bwq4 \
  --idempotency-key "ghosthub-official-homebrew-cask" \
  --agent
```

- [ ] **Step 2: Remove local Superpowers artifacts**

Delete the spec and both plans named above. Verify:

```bash
git status --short
git diff -- docs/superpowers
```

Expected: only the three planning artifacts are deleted; no implementation
file is affected.

- [ ] **Step 3: Commit planning-artifact cleanup**

Invoke `kenn:commit`, then commit only those deletions with a body explaining
that repository policy excludes local Superpowers artifacts from pull requests.

- [ ] **Step 4: Run final verification from a clean worktree**

Run:

```bash
make docs-build
cd website
pnpm check
pnpm lint
pnpm test
pnpm build
cd ..
git status --short --branch
```

Expected: every check succeeds and the worktree is clean.

- [ ] **Step 5: Publication handoff**

Publish the tap before changing public Ghosthub instructions. If the user has
explicitly authorized push/PR operations, push and open the tap PR first; after
its cask is merged and `brew install kenn-io/tap/ghosthub` succeeds from tap
`main`, push/open the Ghosthub PR. Do not deploy ghosthub.ai until the cask is
available, and run `make site-deploy` only with explicit deployment authority.
