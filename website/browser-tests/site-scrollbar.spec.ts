import { expect, test, type Page } from '@playwright/test';

const WIDTH = 1700;

test.beforeEach(async ({ page }) => {
  await page.route('https://api.github.com/**', (route) => route.abort());
});

async function brandX(page: Page): Promise<number | undefined> {
  const brand = page.locator('header .brand');
  await expect(brand).toBeVisible();
  return (await brand.boundingBox())?.x;
}

function scrollbarWidth(page: Page): Promise<number> {
  return page.evaluate(
    () => window.innerWidth - document.documentElement.clientWidth,
  );
}

function pageOverflows(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const root = document.documentElement;
    return root.scrollHeight > root.clientHeight;
  });
}

test('keeps the page in place while the screenshot lightbox opens and closes', async ({
  page,
}) => {
  await page.setViewportSize({ width: WIDTH, height: 800 });
  await page.goto('/overview/');
  const before = await brandX(page);
  expect(await scrollbarWidth(page)).toBeGreaterThan(0);

  await page.locator('[data-lightbox-trigger]').first().click();
  await expect(page.locator('dialog[open]')).toBeVisible();
  expect(await brandX(page)).toBe(before);

  await page.locator('[data-image-lightbox-close]').click();
  await expect(page.locator('body')).not.toHaveClass(/lightbox-open/);
  expect(await scrollbarWidth(page)).toBeGreaterThan(0);
  expect(await brandX(page)).toBe(before);
});

test('keeps the column in place when moving from a page that fits to one that scrolls', async ({
  page,
}) => {
  await page.setViewportSize({ width: WIDTH, height: 800 });
  await page.goto('/');
  const height = await page.evaluate(
    () => document.documentElement.scrollHeight,
  );
  await page.setViewportSize({ width: WIDTH, height });
  expect(await pageOverflows(page)).toBe(false);
  const before = await brandX(page);

  await page.getByRole('link', { name: 'Overview', exact: true }).first().click();
  await page.waitForURL('**/overview/');

  expect(await pageOverflows(page)).toBe(true);
  expect(await scrollbarWidth(page)).toBeGreaterThan(0);
  expect(await brandX(page)).toBe(before);
});
