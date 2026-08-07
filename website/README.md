# ghosthub.ai

Marketing site for Ghosthub. Astro static site, deployed through Vercel's
CLI. `.github/workflows/website.yml` is CI only (check, lint, test, build); it
does not deploy.

The public, task-oriented Zensical documentation lives in `docs/` and is
published under `/docs/` by the same build. Each documentation page is also
published as Markdown at its sibling `.md` URL, and `docs/llms.txt` becomes
`/llms.txt`. The repository-root `docs/` directory remains internal engineering
documentation and has a separate build.

    pnpm install
    pnpm dev        # local dev server
    pnpm check      # type-check templates
    pnpm lint       # oxlint
    pnpm test       # vitest unit tests
    pnpm build      # production build to dist/

The website build uses `uv` for Zensical. CI installs it directly; other clean
build environments use the checksum-pinned bootstrap in `scripts/run-uv.sh`.
To preview only the public docs:

    uv run --project docs zensical serve --config-file zensical.toml

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

## Product screenshots

`src/assets/*.png` is gitignored; binaries live on the orphan
`website-assets` branch and `scripts/sync-assets.sh` materializes the required set
(it runs automatically via `pnpm dev`, `pnpm check`, and `pnpm build`).
The script degrades to a generated placeholder only when
`SYNC_ASSETS_ALLOW_PLACEHOLDER` is set (CI does this while the repo is
private); production builds fail instead of silently deploying a
placeholder or partial set. Successfully fetched assets get local checksum
sidecars, so unmarked legacy placeholders are never reused by an offline
production build.

To refresh every screenshot, use the faux environment in `demo/`. It never
shows real project or host details, and `shoot.sh` drives the exact staged
process through every documented UI state:

    cd website/demo
    ./stage.sh && ./run.sh && ./shoot.sh /tmp/ghosthub-website-assets
    ./teardown.sh   # always run: stops demo processes and removes scratch state

The staged app receives an explicit demo-only OpenSSH configuration and
known-hosts file under the guarded scratch directory. Discovery and attachment
therefore cannot inherit the developer's SSH aliases, proxies, or host trust.

The injected demo controller drives and captures only its exact staged
process, so the workflow needs neither Accessibility nor Screen Recording
permission. `shoot.sh` preserves native window and tab chrome, including both
the three-by-two command center and native tab group, and writes optimized PNGs
with the exact filenames expected by the site.
Commit those files on `website-assets` and push that branch. Pushing
`website-assets` does not redeploy the site by itself: trigger a Vercel
redeploy (dashboard, or any push to the production branch) to publish them.
