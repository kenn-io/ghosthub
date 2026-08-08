# Ghosthub User Documentation

This directory contains the public, task-oriented documentation published at
[ghosthub.ai/docs](https://ghosthub.ai/docs/). The visual
[Overview](https://ghosthub.ai/overview/) is a short product tour; detailed
instructions belong here.

Build the complete website from `website/`:

```bash
corepack pnpm build
```

Preview only the Zensical documentation while editing:

```bash
uv run --project docs zensical serve --config-file zensical.toml
```

Keep page sources flat in `content/`. A source named `sessions.md` is published
as both `/docs/sessions/` and `/docs/sessions.md`. The landing page is published
as `/docs/` and `/docs.md`. Add every public page to `zensical.toml` and
`llms.txt`.
