# ghosthub.ai

Astro static site for the Ghosthub landing page, five-minute overview, and
public user guides, deployed with the Vercel CLI.
`.github/workflows/website.yml` runs CI only (`check`, `lint`, `test`, `build`)
and does not deploy.

See [Documentation publishing](../docs/README.md) for page ownership, URLs,
release labels, and required checks. Public guides live in `docs/content/`;
engineering references live in repository-root `docs/`.

```sh
pnpm install --frozen-lockfile
pnpm dev           # local dev server
pnpm check         # Astro type-check
pnpm lint          # oxlint
pnpm test          # vitest unit tests
pnpm build         # production build to dist/
pnpm test:browser  # scrollbar layout tests against dist/ (needs Chrome and a build)
```

`scripts/run-uv.sh` fetches a checksum-verified `uv` binary into
`website/.cache/` and rechecks it before every run in local, CI, and deployment
builds. The changelog lives at `docs/content/changelog.md`. To preview just the
public docs:

```sh
./scripts/run-uv.sh run --project docs --frozen zensical serve --config-file zensical.toml
```

Site-wide constants (repo slug, Discord invite, Homebrew command) live in
`src/config.ts`.

## Deployment

Link the repository root to the Vercel project once (keep the Vercel project
root directory set to `website`; never link from inside `website/`):

```sh
vercel link
```

Then build and deploy to production from the repository root:

```sh
make site-deploy
```

`make site-deploy` builds the site first (syncing screenshots from
`website-assets`), then runs `vercel deploy --prod`. Repository-root
`.vercelignore` limits the upload to the website files.

## Product screenshots

`src/assets/*.png` is gitignored. Screenshot binaries live on the orphan
`website-assets` branch and `scripts/sync-assets.sh` materializes them
automatically during `pnpm dev`, `pnpm check`, and `pnpm build`. Placeholders
are generated only when `SYNC_ASSETS_ALLOW_PLACEHOLDER` is set; production
builds require the full real set. Fetched assets get local checksum sidecars so
an offline production build can never reuse unmarked placeholders.

Use the synthetic demo in `demo/` for the main capture set. It requires a built
`Ghosthub.app`, tmux, and Docker (the Docker remote listens on loopback port
2201). Set `GHOSTHUB_DEMO_APP` if your bundle is not at
`dist/release/Ghosthub.app`. `shoot.sh` drives only the staged app and leaves
your regular Ghosthub instance alone:

```sh
cd website/demo
./stage.sh && ./run.sh
GHOSTHUB_DEMO_SKIP_SESSION_PREVIEWS=1 ./shoot.sh /tmp/ghosthub-website-assets
GHOSTHUB_DEMO_SESSION_PREVIEW_MODE=always-live ./run.sh
GHOSTHUB_DEMO_ALWAYS_LIVE_PREVIEW_ONLY=1 ./shoot.sh /tmp/ghosthub-website-assets
GHOSTHUB_DEMO_EXE_ACCOUNTS=1 ./run.sh
GHOSTHUB_DEMO_EXE_ONLY=1 ./shoot.sh /tmp/ghosthub-website-assets
GHOSTHUB_DEMO_HERDR_CORE=1 ./run.sh
GHOSTHUB_DEMO_HERDR_CORE_ONLY=1 ./shoot.sh /tmp/ghosthub-website-assets
./teardown.sh   # always run to stop demo processes and clean up scratch state
```

Capture Settings panes, project recovery, worktree flags, and the
launch-profile sheet directly from SwiftUI views with synthetic data (run from
the repository root):

```sh
make screenshot-settings SCREENSHOT_DIR=/tmp/ghosthub-website-assets
make screenshot-project-recovery SCREENSHOT_PATH=/tmp/ghosthub-website-assets/guide-project-recovery.png
make screenshot-worktree-flags SCREENSHOT_DIR=/tmp/ghosthub-worktree-flags
website/demo/render-launch-profile.sh /tmp/ghosthub-website-assets/docs-launch-profiles.png
```

- Run `make screenshot-settings` after the demo capture so it uses the matching
  host list alongside Keyboard and Privacy views (it opens test windows only;
  no host discovery or terminal processes run). It also writes
  `guide-welcome.png` and `guide-agent-hooks.png` from synthetic hook status.
- `make screenshot-worktree-flags` exercises real sidebar actions with isolated
  preferences and writes `worktree-flags-light.png` and
  `worktree-flags-dark.png`. Publish the dark capture as
  `guide-worktree-flags.png`.
- The staged demo app uses its own OpenSSH config, known-hosts file, and tmux
  socket directory (its tmux wrapper restores that directory for kwt commands
  that clear `TMUX_TMPDIR`). Because the controller captures its own process,
  it needs neither Accessibility nor Screen Recording permission.
- The controller also accepts `next-sibling`, `previous-sibling`, and
  `close-session` to test default shortcuts against the staged window.

Before publishing, inspect every changed screenshot at full resolution and
check its metadata for private data. Keep native window and tab controls
visible. Add any new filenames to `scripts/sync-assets.sh`, commit the PNGs to
the orphan `website-assets` branch (never to the app branch), and run
`make site-deploy` from the repo root when ready to publish (pushing
`website-assets` alone does not deploy).
