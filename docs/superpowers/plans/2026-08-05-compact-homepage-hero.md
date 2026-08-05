# Compact Homepage Hero Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore a clearly secondary `Learn More` path in the homepage hero while keeping Homebrew dominant and moving the product screenshot upward.

**Architecture:** Extend the reusable Astro install component with an optional named slot rendered beside its existing DMG fallback. The homepage fills that slot with the Guide link; the Guide page leaves it empty. Component rendering verifies the optional-action contract, while scoped CSS preserves the hierarchy and tightens only the homepage spacing.

**Tech Stack:** Astro 7, TypeScript, Vitest, CSS

## Global Constraints

- Keep `brew install kenn-io/tap/ghosthub` as the hero's only primary control.
- Render `Learn More` as a visually secondary link to `/guide/` beside the DMG fallback.
- Preserve the current copy button, visible `aria-live` feedback, DMG fallback, and Guide-page behavior.
- Allow the secondary row to wrap cleanly on narrow screens.
- Do not change Guide copy, application behavior, screenshot assets, or deployment behavior.
- Do not encode exact CSS values in tests.

---

### Task 1: Optional Install Secondary Action

**Files:**
- Create: `website/vitest.config.ts`
- Create: `website/src/components/InstallCommand.test.ts`
- Modify: `website/src/components/InstallCommand.astro`

**Interfaces:**
- Consumes: existing `InstallCommand` default rendering and `RELEASES_URL`
- Produces: an optional named Astro slot called `secondary`, placed in the fallback-link row

- [ ] **Step 1: Configure Vitest to compile Astro components**

```ts
import { getViteConfig } from 'astro/config';

export default getViteConfig({
  test: {
    include: ['src/**/*.test.ts'],
  },
});
```

- [ ] **Step 2: Write the failing component tests**

```ts
import { experimental_AstroContainer as AstroContainer } from 'astro/container';
import { beforeAll, describe, expect, it } from 'vitest';
import InstallCommand from './InstallCommand.astro';

describe('InstallCommand', () => {
  let container: AstroContainer;

  beforeAll(async () => {
    container = await AstroContainer.create();
  });

  it('renders a supplied secondary action beside the DMG fallback', async () => {
    const html = await container.renderToString(InstallCommand, {
      slots: {
        secondary: '<a href="/guide/">Learn More</a>',
      },
    });

    expect(html).toContain('href="/guide/"');
    expect(html.indexOf('download the DMG')).toBeLessThan(
      html.indexOf('Learn More'),
    );
  });

  it('omits the secondary action when no slot is supplied', async () => {
    const html = await container.renderToString(InstallCommand);

    expect(html).not.toContain('href="/guide/"');
  });
});
```

- [ ] **Step 3: Run the focused test and verify RED**

Run: `cd website && pnpm vitest run src/components/InstallCommand.test.ts`

Expected: FAIL because `InstallCommand` does not render the `secondary` slot.

- [ ] **Step 4: Add the optional slot to the fallback row**

In `InstallCommand.astro`, check `Astro.slots.has('secondary')`, replace the standalone `.download` link with a `.secondary-actions` row, and render this conditional sibling after the DMG link:

```astro
{
  hasSecondary && (
    <>
      <span class="separator" aria-hidden="true">&middot;</span>
      <slot name="secondary" />
    </>
  )
}
```

Give `.secondary-actions` a centered wrapping flex layout with a small gap. Keep the existing `.download` typography and hover treatment; make the separator use `var(--text-faint)`.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run: `cd website && pnpm vitest run src/components/InstallCommand.test.ts`

Expected: both component tests PASS.

- [ ] **Step 6: Commit the reusable component contract**

```bash
git add website/vitest.config.ts website/src/components/InstallCommand.test.ts website/src/components/InstallCommand.astro
git commit -m "Support secondary install actions"
```

### Task 2: Restore and Tighten the Homepage Hero

**Files:**
- Modify: `website/src/components/Hero.astro`

**Interfaces:**
- Consumes: the `InstallCommand` named slot `secondary`
- Produces: the homepage-only `/guide/` `Learn More` action

- [ ] **Step 1: Write the failing homepage rendering test**

Import `Hero.astro` and add this test to
`website/src/components/InstallCommand.test.ts`:

```ts
it('keeps Homebrew primary while exposing the Guide', async () => {
  const html = await container.renderToString(Hero);
  const commandIndex = html.indexOf('brew install kenn-io/tap/ghosthub');
  const guideIndex = html.indexOf('href="/guide/"');

  expect(commandIndex).toBeGreaterThan(-1);
  expect(guideIndex).toBeGreaterThan(commandIndex);
  expect(html.slice(guideIndex)).toContain('Learn More');
});
```

- [ ] **Step 2: Run the homepage test and verify RED**

Run: `cd website && pnpm vitest run src/components/InstallCommand.test.ts -t "keeps Homebrew primary"`

Expected: FAIL because the current hero has no Guide link.

- [ ] **Step 3: Fill the secondary slot from the homepage**

Replace the self-closing install component in `Hero.astro` with:

```astro
<InstallCommand>
  <a class="learn" href="/guide/" slot="secondary">
    Learn More <span aria-hidden="true">&rarr;</span>
  </a>
</InstallCommand>
```

Style `.learn` with the mono font, the accent color, an underline matching the existing fallback-link treatment, and a subtle hover to `var(--text)`. Do not add a button border, background, or shadow.

- [ ] **Step 4: Tighten homepage-only spacing**

Reduce `.sub`'s bottom margin from `1.6rem` to `1.35rem`, reduce `.window`'s top margin from `3.5rem` to `2.5rem`, and leave the install component's feedback spacing untouched.

- [ ] **Step 5: Run focused and full website verification**

Run:

```bash
cd website
pnpm test
pnpm check
pnpm lint
pnpm build
```

Expected: all component and library tests pass, Astro reports no errors, lint is clean, and the production build completes.

- [ ] **Step 6: Commit the homepage change**

```bash
git add website/src/components/Hero.astro website/src/components/InstallCommand.test.ts
git commit -m "Restore the homepage Guide path"
```
