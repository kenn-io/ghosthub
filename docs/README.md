# Documentation publishing

Ghosthub has two documentation sites: public guides for people using the app,
and engineering references for Kenn engineers and approved contributors. The
root README introduces Ghosthub and links to both.

## Where does a page belong?

| Content | Source | Published location |
| --- | --- | --- |
| Product landing page and five-minute tour | `website/src/` | [ghosthub.ai](https://ghosthub.ai/) and `/overview/` |
| User setup, tasks, limits, and troubleshooting | `website/docs/content/` | [ghosthub.ai/docs](https://ghosthub.ai/docs/) |
| Architecture, development, operations, and release steps | `docs/` | Engineering site built with `make docs-build` |
| Release history | `website/docs/content/changelog.md` | [ghosthub.ai/docs/changelog](https://ghosthub.ai/docs/changelog/) and Sparkle appcast notes |
| Product screenshots | Orphan `website-assets` branch | Synced into website and docs assets during the website build |

Give each topic one owning page. Keep exact steps and limits there and link to
it from summaries. The [public docs index](../website/docs/content/index.md)
routes users to tasks; the [engineering index](index.md) routes maintainers to
references. Follow the [writing guidance](../AGENTS.md#documentation).

## How public pages are published

Keep public Markdown files flat inside `website/docs/content/`. A file named
`sessions.md` generates both `/docs/sessions/` and `/docs/sessions.md`;
`index.md` generates `/docs/` and `/docs.md`. Both HTML and Markdown outputs
come from the same file, so never maintain a separate copy for agents.

Add every new public page to both `website/zensical.toml` and
`website/docs/llms.txt`. Reference screenshots as `/docs/assets/<filename>.png`
so links work from both HTML pages and Markdown copies (including `/docs.md`),
and register each filename in `website/scripts/sync-assets.sh` so production
builds cannot miss it.

Public docs track `main`. Label anything not yet shipped as **Unreleased**,
link to the changelog, and keep download links pointed at the latest stable
release. Never hardcode the current version number in guides; `RELEASE_VERSION`
owns it. See [Release](release.md) when preparing or publishing binaries.

## Checking documentation changes

Build the engineering docs from the repository root:

```sh
make docs-build
```

Check and build the public site from `website/`:

```sh
pnpm install --frozen-lockfile
pnpm check
pnpm lint
pnpm test
pnpm build
pnpm test:browser
```

The website build runs Zensical in strict mode, copies the changelog, and checks
that every page has both HTML and Markdown outputs. After building, open
changed pages at desktop and mobile widths, follow their links, and inspect
screenshots at full resolution.

For local previews, run `make docs-serve`, `make site-docs-serve`, or `pnpm dev`
inside `website/`.

CI runs the shared
[first-paint check](https://github.com/kenn-io/actions/tree/main/first-paint) on
the built website, both docs sites, and the Rust web UI. It fails if a page can
paint before its stylesheets and fonts load. Website and docs pages embed their
fonts in a render-blocking stylesheet and inline `hold-first-paint.js` right
after `<meta charset>` (the Rust web UI uses system fonts only and needs
neither). Both Zensical sites share `website/docs/overrides/` for that script,
its template, and the embedded Inter and JetBrains Mono faces; keep the theme's
Google Fonts loading off (`font = false`). To run the check locally, set up a
`kenn-io/actions` checkout per its README and run
`node <checkout>/first-paint/check-first-paint.mjs --dist <built site>`.

## Refreshing screenshots and deploying

Follow [website/README.md](../website/README.md). Use synthetic demo data,
inspect every outgoing image at full resolution, and keep screenshot binaries
on `website-assets`. Refresh screenshots only after a feature is accepted.
Pushing `website-assets` alone does not deploy the site.

## Design documents

Keep maintained references focused on current behavior. Clearly label approved
unbuilt work and proposals, and link them from the separate section in
[docs/index.md](index.md). Keep decisions, approvals, and active exceptions
with their removal conditions, and keep superseded designs outside main
navigation.

Agent instructions live in the root [AGENTS.md](../AGENTS.md), with
[CLAUDE.md](../CLAUDE.md) symlinked to it.
