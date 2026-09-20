# Documentation publishing

Ghosthub has two documentation sites. Public guides help people use the app.
Engineering references help Kenn engineers and approved contributors maintain
it. The root README introduces the product and links to those guides.

## Where does a page belong?

| Content | Source | Published location |
| --- | --- | --- |
| Product introduction and visual tour | `website/src/` | [ghosthub.ai](https://ghosthub.ai/) and `/overview/` |
| User setup, tasks, limits, and troubleshooting | `website/docs/content/` | [ghosthub.ai/docs](https://ghosthub.ai/docs/) |
| Architecture, development, operations, and release procedures | `docs/` | Separate engineering site built with `make docs-build` |
| Release history | Root `CHANGELOG.md` | Copied into the public docs during the website build |
| Product screenshots | Orphan `website-assets` branch | Copied into both website and docs assets during the website build |

Give each topic one owner. Keep exact steps and limits in that guide, and link
to it from summaries. The [public documentation index](../website/docs/content/index.md)
routes users to tasks. The [engineering index](index.md) routes maintainers to
references. Follow the [writing guidance](../AGENTS.md#documentation).

## How are public pages published?

Keep public Markdown sources flat in `website/docs/content/`. A page named
`sessions.md` produces both `/docs/sessions/` and `/docs/sessions.md`. The index
produces `/docs/` and `/docs.md`. The build copies the same Markdown sources;
do not maintain a separate version for machine readers.

Add public pages to both `website/zensical.toml` and `website/docs/llms.txt`.
Use `/docs/assets/<filename>.png` for screenshots so links resolve from HTML
pages and Markdown companions, including `/docs.md`. Add each screenshot to
`website/scripts/sync-assets.sh` so a production build cannot omit it.

The public docs follow `main`. Describe newer features as unreleased until
published, link to the canonical changelog, and keep stable downloads pointed
at the latest release. Do not copy the current version number into guides;
`RELEASE_VERSION` owns it. See the [release procedure](release.md) when preparing
or publishing binaries.

## How do I check documentation changes?

From the repository root, build the engineering site:

```sh
make docs-build
```

From `website/`, install the pinned dependencies and check the public site:

```sh
pnpm install --frozen-lockfile
pnpm check
pnpm lint
pnpm test
pnpm build
```

The website build checks the public docs in strict mode, copies the changelog,
and verifies that each page has HTML and Markdown output. Also open changed
pages at desktop and narrow widths. Follow their links and check screenshots
at full resolution. Build success alone does not check the wording or layout.

For local previews, use `make docs-serve`, `make site-docs-serve`, or
`pnpm dev` from `website/`.

## How do I refresh screenshots and deploy?

Follow the [website capture and deployment instructions](../website/README.md).
Use synthetic demo data, inspect every outgoing image, and keep screenshot
binaries on `website-assets`. Refresh screenshots after the feature is accepted.
Pushing that branch alone does not deploy the website.

## Where do design documents go?

Describe current behavior in maintained references. Label approved but unbuilt
work and proposals, and link to them from the separate design section of the
[engineering index](index.md). Preserve decisions, approvals, and active
exceptions with their removal conditions. Keep superseded designs outside the
normal site navigation.

Agent instructions stay in the root [AGENTS.md](../AGENTS.md), with
[CLAUDE.md](../CLAUDE.md) referring to the same guide.
