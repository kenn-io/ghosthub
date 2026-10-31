import { defineConfig } from '@playwright/test';

const chromePath = process.env['PLAYWRIGHT_CHROME_PATH'];
const port = 4329;

export default defineConfig({
  testDir: 'browser-tests',
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
