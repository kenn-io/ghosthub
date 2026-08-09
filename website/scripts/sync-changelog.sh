#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
website_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$website_root/.." && pwd)"

cp -f "$repo_root/CHANGELOG.md" "$website_root/docs/content/changelog.md"
