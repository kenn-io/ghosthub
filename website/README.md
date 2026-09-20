# ghosthub.ai

The website introduces Ghosthub and publishes its user guides. It is an Astro
static site deployed through Vercel's CLI. `.github/workflows/website.yml` is CI only (check, lint, test, build); it
does not deploy.

Read [Documentation publishing](../docs/README.md) for page ownership, public
HTML and Markdown URLs, release labels, and required checks. User guides live
in `docs/content/`; repository-root `docs/` holds engineering references.

    pnpm install --frozen-lockfile
    pnpm dev        # local dev server
    pnpm check      # type-check templates
    pnpm lint       # oxlint
    pnpm test       # vitest unit tests
    pnpm build      # production build to dist/

The website build downloads repository-supported `uv` platform archives with
repository-pinned archive and executable checksums through `scripts/run-uv.sh`
in local, CI, and deployment environments. The verified binary is cached under
`website/.cache/` and rechecked before every use. The build copies the canonical
repository-root changelog into the public docs. To preview only the public docs:

    bash scripts/sync-changelog.sh
    ./scripts/run-uv.sh run --project docs --frozen zensical serve --config-file zensical.toml

Constants (repo slug, Discord invite) live in `src/config.ts`.

## Deployment

Link the repository root to the Vercel project once. Keep the Vercel project
root directory set to `website`; do not link from inside `website/`:

    vercel link

Then deploy the current workspace to production from the repository root:

    make site-deploy

The target builds the site first, which downloads the screenshot set from the
`website-assets` branch, then runs `vercel deploy --prod`. The repository-root
`.vercelignore` limits the upload to the website project and canonical
changelog.

## Product screenshots

`src/assets/*.png` is gitignored; binaries live on the orphan
`website-assets` branch and `scripts/sync-assets.sh` materializes the required set
(it runs automatically via `pnpm dev`, `pnpm check`, and `pnpm build`).
The script degrades to a generated placeholder only when
`SYNC_ASSETS_ALLOW_PLACEHOLDER` is set. Production builds require the complete
real set. Successfully fetched assets get local checksum
sidecars, so unmarked legacy placeholders are never reused by an offline
production build.

Use the synthetic environment in `demo/` for the main capture set. It needs a
built `Ghosthub.app`, tmux, and a running Docker engine. The Docker remote uses
loopback port 2201. Set `GHOSTHUB_DEMO_APP` to a current app bundle if it is not
at `dist/release/Ghosthub.app`. `shoot.sh` controls the staged app, leaving any
normal Ghosthub instance alone:

    cd website/demo
    ./stage.sh && ./run.sh
    GHOSTHUB_DEMO_SKIP_SESSION_PREVIEWS=1 ./shoot.sh /tmp/ghosthub-website-assets
    GHOSTHUB_DEMO_SESSION_PREVIEW_MODE=always-live ./run.sh
    GHOSTHUB_DEMO_ALWAYS_LIVE_PREVIEW_ONLY=1 ./shoot.sh /tmp/ghosthub-website-assets
    GHOSTHUB_DEMO_EXE_ACCOUNTS=1 ./run.sh
    GHOSTHUB_DEMO_EXE_ONLY=1 ./shoot.sh /tmp/ghosthub-website-assets
    ./teardown.sh   # always run: stops demo processes and removes scratch state

Capture the Settings pages, project recovery, and launch-profile sheet from
the real SwiftUI views with synthetic data. From the repository root:

    make screenshot-settings SCREENSHOT_DIR=/tmp/ghosthub-website-assets
    make screenshot-project-recovery SCREENSHOT_PATH=/tmp/ghosthub-website-assets/guide-project-recovery.png
    website/demo/render-launch-profile.sh /tmp/ghosthub-website-assets/docs-launch-profiles.png

Run the Settings renderer after the demo capture to use the current host list
alongside matching Keyboard and Privacy views. It opens only test windows;
no host discovery or terminal process is needed.

The staged app uses its own OpenSSH configuration, known-hosts file, and tmux
socket directory. The demo tmux wrapper restores that directory for kwt
commands that clear `TMUX_TMPDIR`. The controller captures its own process,
so it needs neither Accessibility nor Screen Recording permission.

Before publishing, view every changed screenshot at full resolution and check
its metadata for private data. Keep native window and tab controls visible.
Add new filenames to `scripts/sync-assets.sh`, then commit the PNGs to the
orphan `website-assets` branch. Do not add binaries to the app branch.

Pushing `website-assets` does not deploy the site. Run `make site-deploy` from
the repository root when the website is ready to publish.
