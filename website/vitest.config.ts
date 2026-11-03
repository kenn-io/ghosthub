import { getViteConfig } from 'astro/config';

const onGitHubActions = process.env['GITHUB_ACTIONS'] === 'true';

export default getViteConfig({
  test: {
    include: ['src/**/*.test.ts'],
    // On GitHub Actions, retry failed tests and write a JSON report that CI
    // uploads. Our CI flake monitor reads that report: a test that failed and
    // then passed on a retry reports "passed" with its earlier failure
    // messages. The tree reporter names every test in the log, and naming any
    // reporter replaces Vitest's defaults, so keep its github-actions reporter
    // for failure annotations.
    ...(onGitHubActions
      ? {
          retry: 2,
          reporters: [
            'tree',
            'github-actions',
            ['json', { outputFile: 'test-results/vitest/website.json' }],
          ],
        }
      : {}),
  },
});
