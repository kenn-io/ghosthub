import { getViteConfig } from 'astro/config';

export default getViteConfig({
  test: {
    include: ['src/**/*.test.ts'],
    // On GitHub Actions, the tree reporter lists every test with its result
    // under its file, so our CI flake monitor can confirm that a test which
    // failed passed on a rerun; the default reporter names only files there.
    // Naming any reporter replaces Vitest's defaults, so keep its
    // github-actions reporter for failure annotations.
    ...(process.env['GITHUB_ACTIONS'] === 'true'
      ? { reporters: ['tree', 'github-actions'] }
      : {}),
  },
});
