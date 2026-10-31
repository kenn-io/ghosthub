import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, test } from '@playwright/test';

const ASSETS = fileURLToPath(new URL('../../rust/web/assets/', import.meta.url));
const VENDORED = new Set([
  'xterm.css',
  'xterm.js',
  'addon-fit.js',
  'addon-unicode11.js',
]);

const INVENTORY = {
  demo: true,
  hosts: [
    {
      name: 'local-host',
      kind: 'local',
      status: 'ready',
      endpoint: 'local',
      herdr_available: false,
      zellij_available: false,
      tmux_sessions: [],
      herdr_sessions: [],
      zellij_sessions: [],
      projects: [],
      console: { name: 'console', subtitle: 'Local console shell', live: true },
    },
    {
      name: 'remote-host',
      kind: 'ssh',
      status: 'ready',
      endpoint: 'dev@remote-host',
      herdr_available: false,
      zellij_available: false,
      tmux_sessions: [
        'alpha',
        'bravo',
        'charlie',
        'delta',
        'echo',
        'foxtrot',
        'golf',
        'hotel',
        'india',
        'juliet',
      ].map((name) => ({ name, subtitle: 'Tmux session' })),
      herdr_sessions: [],
      zellij_sessions: [],
      projects: [],
    },
  ],
};

test('keeps sidebar controls in place when expanding a host makes the sidebar scroll', async ({
  page,
}) => {
  // Every request is answered here, so the page sees the Rust web UI's assets
  // without running its server.
  await page.route('**/*', (route) => {
    const { pathname } = new URL(route.request().url());
    if (pathname === '/') {
      return route.fulfill({ path: join(ASSETS, 'index.html') });
    }
    if (pathname === '/api/v1/inventory') {
      return route.fulfill({ json: INVENTORY });
    }
    const name = pathname.replace('/assets/', '');
    return route.fulfill({
      path: join(ASSETS, VENDORED.has(name) ? 'vendor' : '', name),
    });
  });
  await page.setViewportSize({ width: 1280, height: 400 });
  await page.goto('/');

  const remote = page.locator('.host-header', { hasText: 'remote-host' });
  const add = page.getByTitle('New console');
  const sidebar = page.locator('#sidebar');
  await remote.click();
  expect(
    await sidebar.evaluate((el) => el.scrollHeight > el.clientHeight),
  ).toBe(false);
  const collapsed = await add.boundingBox();

  await remote.click();
  expect(
    await sidebar.evaluate((el) => el.scrollHeight > el.clientHeight),
  ).toBe(true);
  // Without a scrollbar the difference is the sidebar's 1 px right border.
  expect(
    await sidebar.evaluate(
      (el) => (el as HTMLElement).offsetWidth - el.clientWidth,
    ),
  ).toBeGreaterThan(1);
  const expanded = await add.boundingBox();

  expect(expanded?.x).toBe(collapsed?.x);
});
