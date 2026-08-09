#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
website_root="$(cd "$script_dir/.." && pwd)"
docs_root="$website_root/docs"
output_root="$website_root/public"

bash "$script_dir/sync-changelog.sh"

(
  cd "$website_root"
  "$script_dir/run-uv.sh" \
    run --project docs --frozen \
    zensical build --strict --config-file zensical.toml
)

cp -f "$docs_root/content/index.md" "$output_root/docs.md"

for source in "$docs_root"/content/*.md; do
  name="$(basename "$source")"
  if [[ "$name" == "index.md" ]]; then
    continue
  fi
  cp -f "$source" "$output_root/docs/$name"
done

cp -f "$docs_root/llms.txt" "$output_root/llms.txt"

for source in "$docs_root"/content/*.md; do
  name="$(basename "$source" .md)"
  if [[ "$name" == "index" ]]; then
    html="$output_root/docs/index.html"
    markdown="$output_root/docs.md"
  else
    html="$output_root/docs/$name/index.html"
    markdown="$output_root/docs/$name.md"
  fi

  if [[ ! -s "$html" || ! -s "$markdown" ]]; then
    printf 'missing generated documentation pair for %s\n' "$source" >&2
    exit 1
  fi
done

if [[ ! -s "$output_root/llms.txt" ]]; then
  printf 'missing generated llms.txt\n' >&2
  exit 1
fi
