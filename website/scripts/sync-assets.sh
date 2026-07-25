#!/usr/bin/env bash
# Materializes binary assets from the orphan website-assets branch into
# src/assets/. Screenshot binaries live there so refreshes never bloat
# main's history.
#
# Resolution order: git fetch (local dev, CI with credentials), local
# branch, raw.githubusercontent.com (Vercel builds have no usable .git;
# works once the repo is public), pre-existing verified file. Generated
# placeholders are a last resort and only when
# SYNC_ASSETS_ALLOW_PLACEHOLDER is set, so production can never silently
# deploy without the real asset set.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p src/assets

assets=(
  hero.png
  guide-sessions.png
  guide-hosts.png
  guide-worktree.png
  guide-quick-launch.png
  guide-terminal.png
  guide-command-ghosthub.png
  guide-command-agentsview.png
  guide-command-scratch.png
  guide-command-export.png
  guide-command-release.png
  guide-command-tests.png
)
raw_root="https://raw.githubusercontent.com/kenn-io/ghosthub/website-assets"
fetched_ref=""

if git fetch --depth=1 origin website-assets 2>/dev/null; then
  fetched_ref="FETCH_HEAD"
fi

record_synced_asset() {
  local path="$1"
  shasum -a 256 "$path" > "$path.synced"
}

asset_is_synced() {
  local path="$1"
  [[ -f "$path.synced" ]] \
    && shasum -a 256 -c "$path.synced" >/dev/null 2>&1
}

show_asset() {
  local ref="$1" asset="$2" destination="$3"
  git show "$ref:$asset" > "$destination.tmp" 2>/dev/null || {
    rm -f "$destination.tmp"
    return 1
  }
  mv -f "$destination.tmp" "$destination"
}

generate_placeholder() {
  local asset="$1" path="$2"
  ASSET_NAME="$asset" node -e '
    const sharp = require("sharp");
    const label = process.env.ASSET_NAME;
    const svg = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="966">
         <rect width="100%" height="100%" fill="#0d1420"/>
         <text x="50%" y="50%" fill="#5f6870" font-size="28"
               font-family="monospace" text-anchor="middle">
           ${label} placeholder
         </text>
       </svg>`
    );
    sharp(svg).png().toFile(process.argv[1]);
  ' "$path"
}

sync_asset() {
  local asset="$1"
  local path="src/assets/$asset"
  local placeholder="$path.placeholder"

  if [[ -n "$fetched_ref" ]] \
    && show_asset "$fetched_ref" "$asset" "$path"; then
    rm -f "$placeholder"
    record_synced_asset "$path"
    echo "synced $path from origin/website-assets"
  elif git rev-parse --verify --quiet website-assets >/dev/null 2>&1 \
    && show_asset website-assets "$asset" "$path"; then
    rm -f "$placeholder"
    record_synced_asset "$path"
    echo "synced $path from local website-assets"
  elif curl -fsSL --max-time 30 \
    -o "$path.tmp" "$raw_root/$asset" 2>/dev/null; then
    mv -f "$path.tmp" "$path"
    rm -f "$placeholder"
    record_synced_asset "$path"
    echo "synced $path from raw.githubusercontent.com"
  elif [[ -f "$path" && ! -f "$placeholder" ]] \
    && asset_is_synced "$path"; then
    echo "warning: could not reach website-assets; keeping $path" >&2
  elif [[ -f "$path" \
    && -n "${SYNC_ASSETS_ALLOW_PLACEHOLDER:-}" ]]; then
    echo "warning: could not sync $asset; keeping placeholder" >&2
    rm -f "$path.synced"
    touch "$placeholder"
  elif [[ -n "${SYNC_ASSETS_ALLOW_PLACEHOLDER:-}" ]]; then
    echo "warning: website-assets unreachable; generating $asset placeholder" >&2
    generate_placeholder "$asset" "$path"
    rm -f "$path.synced"
    touch "$placeholder"
  else
    rm -f "$path.tmp"
    echo "error: could not sync $asset from website-assets and $path" >&2
    echo "       is missing or stale. Set SYNC_ASSETS_ALLOW_PLACEHOLDER=1" >&2
    echo "       for CI/dev placeholders, or publish the complete asset set." >&2
    exit 1
  fi
}

for asset in "${assets[@]}"; do
  sync_asset "$asset"
done
