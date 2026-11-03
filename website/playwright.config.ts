import { defineConfig } from '@playwright/test';

const chromePath = process.env['PLAYWRIGHT_CHROME_PATH'];
const port = 4329;
const onGitHubActions = process.env['GITHUB_ACTIONS'] === 'true';

export default defineConfig({
  testDir: 'browser-tests',
  // The list reporter names every test with its result in the log. On GitHub
  // Actions, failed tests are retried and a JSON report is written for CI to
  // upload. Our CI flake monitor reads that report, where a test that failed
  // and then passed on a retry has the status "flaky".
  ...(onGitHubActions
    ? {
        retries: 2,
        reporter: [
          ['list'],
          ['json', { outputFile: 'test-results/playwright/website-browser.json' }],
        ],
      }
    : { reporter: 'list' }),
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
