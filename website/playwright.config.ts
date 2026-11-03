import { defineConfig } from '@playwright/test';

const chromePath = process.env['PLAYWRIGHT_CHROME_PATH'];
const port = 4329;

export default defineConfig({
  testDir: 'browser-tests',
  // The list reporter names every test with its result, so our CI flake
  // monitor can confirm that a test which failed passed on a rerun. It is
  // already the local default; on CI the default dot reporter names only
  // failures.
  reporter: 'list',
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    ...(chromePath === undefined ? { channel: 'chrome' } : {}),
    launchOptions: {
      ...(chromePath === undefined ? {} : { executablePath: chromePath }),
      // Headless Chromium hides scrollbars by default, which would hide the
      // scrollbar-width shifts these tests guard against.
      ignoreDefaultArgs: ['--hide-scrollbars'],
    },
  },
  webServer: {
    command: `pnpm exec astro preview --host 127.0.0.1 --port ${port}`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: false,
  },
});
