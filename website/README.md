# ghosthub.ai

Marketing site for Ghosthub. Astro static site, deployed through Vercel's
CLI. `.github/workflows/website.yml` is CI only (check, lint, test, build); it
does not deploy.

    pnpm install
    pnpm dev        # local dev server
    pnpm check      # type-check templates
    pnpm lint       # oxlint
    pnpm test       # vitest unit tests
    pnpm build      # production build to dist/

Constants (repo slug, Discord invite) live in `src/config.ts`.

## Deployment

Link the repository root to the Vercel project once. Keep the Vercel project
root directory set to `website`; do not link from inside `website/`:

    vercel link

Then deploy the current workspace to production from the repository root:

    make site-deploy

The target builds the site first, which hydrates the hero screenshot from the
`website-assets` branch, then runs `vercel deploy --prod`. The repository-root
`.vercelignore` limits the upload to the website project.

## Hero screenshot

`src/assets/hero.png` is gitignored; binaries live on the orphan
`website-assets` branch and `scripts/sync-assets.sh` materializes them
(it runs automatically via `pnpm dev`, `pnpm check`, and `pnpm build`).
The script degrades to a generated placeholder only when
`SYNC_ASSETS_ALLOW_PLACEHOLDER` is set (CI does this while the repo is
private); production builds fail instead of silently deploying a
placeholder. Successfully fetched assets get a local checksum sidecar, so an
unmarked legacy placeholder is never reused by an offline production build.

To refresh the screenshot, use the faux environment in `demo/`. It never
shows real project or host details:

    cd website/demo
    ./stage.sh && ./run.sh && ./shoot.sh
    ./teardown.sh   # always run: stops demo processes and removes scratch state

The staged app receives an explicit demo-only OpenSSH configuration and
known-hosts file under the guarded scratch directory. Discovery and attachment
therefore cannot inherit the developer's SSH aliases, proxies, or host trust.

Crop the native titlebar (34px at 1x) since Hero.astro renders its own
synthetic titlebar, then commit the result as `hero.png` on
`website-assets` and push that branch. Pushing `website-assets` does not
redeploy the site by itself: trigger a Vercel redeploy (dashboard, or any
push to the production branch) to publish the new screenshot.
