#!/usr/bin/env bash
# Materializes binary assets from the orphan website-assets branch into
# src/assets/. Screenshot binaries live there so refreshes never bloat
# main's history.
#
# Resolution order: fetched git ref (local dev, CI with credentials), then
# complete offline sources when fetch is unavailable: local branch,
# raw.githubusercontent.com, or the pre-existing verified set. Generated
# placeholders are a last resort and only when
# SYNC_ASSETS_ALLOW_PLACEHOLDER is set, so production can never silently
# deploy without the real asset set. Every source is staged as a complete
# generation before any destination file is replaced.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p src/assets

assets=(
  hero.png
  guide-sessions.png
  guide-find.png
  guide-session-previews.png
  guide-session-activity.png
  guide-hosts.png
  guide-tailscale-import.png
  guide-exe-dev.png
  guide-worktree.png
  guide-worktree-window-counts.png
  guide-project-removal.png
  guide-quick-launch.png
  guide-terminal.png
  guide-command-center.png
  guide-native-tabs.png
  guide-window-title.png
)
raw_root="https://raw.githubusercontent.com/kenn-io/ghosthub/website-assets"
fetched_ref=""
stage_root="$(mktemp -d "src/.asset-sync.XXXXXX")"
generation_manifest="src/assets/.website-assets.synced"
placeholder_manifest="src/assets/.website-assets.placeholder"
trap 'rm -rf "$stage_root"' EXIT

if git fetch --depth=1 origin website-assets 2>/dev/null; then
  fetched_ref="FETCH_HEAD"
fi

cached_generation_is_synced() {
  [[ -f "$generation_manifest" ]] \
    && [[ ! -f "$placeholder_manifest" ]] \
    && shasum -a 256 -c "$generation_manifest" >/dev/null 2>&1
}

git_ref_has_complete_set() {
  local ref="$1" asset
  for asset in "${assets[@]}"; do
    if ! git cat-file -e "$ref:$asset" 2>/dev/null; then
      missing_asset="$asset"
      return 1
    fi
  done
}

stage_git_ref() {
  local ref="$1" destination="$2" asset
  mkdir "$destination"
  for asset in "${assets[@]}"; do
    git show "$ref:$asset" > "$destination/$asset" 2>/dev/null || return 1
  done
}

stage_raw_assets() {
  local destination="$1" asset
  mkdir "$destination"
  for asset in "${assets[@]}"; do
    curl -fsSL --max-time 30 \
      -o "$destination/$asset" "$raw_root/$asset" 2>/dev/null || return 1
  done
}

stage_cached_assets() {
  local destination="$1" asset
  mkdir "$destination"
  cached_generation_is_synced || return 1
  for asset in "${assets[@]}"; do
    cp "src/assets/$asset" "$destination/$asset"
  done
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

stage_placeholders() {
  local destination="$1" asset
  mkdir "$destination"
  for asset in "${assets[@]}"; do
    generate_placeholder "$asset" "$destination/$asset"
  done
}

publish_assets() {
  local source="$1" label="$2" placeholders="${3:-}" asset path digest
  local staged_manifest="$source/.website-assets.synced"
  if [[ -z "$placeholders" ]]; then
    for asset in "${assets[@]}"; do
      digest="$(shasum -a 256 "$source/$asset" | awk '{print $1}')"
      printf '%s  src/assets/%s\n' "$digest" "$asset" \
        >> "$staged_manifest"
    done
  fi

  # The manifest is the commit marker for a complete generation. Invalidate
  # the old marker before the first replacement, then publish the new marker
  # with one rename only after every asset has landed.
  rm -f "$generation_manifest" "$placeholder_manifest"
  mkdir -p docs/content/assets
  for asset in "${assets[@]}"; do
    path="src/assets/$asset"
    mv -f "$source/$asset" "$path"
    cp -f "$path" "docs/content/assets/$asset"
    echo "synced $path from $label"
  done
  if [[ -n "$placeholders" ]]; then
    touch "$source/.website-assets.placeholder"
    mv -f "$source/.website-assets.placeholder" "$placeholder_manifest"
  else
    mv -f "$staged_manifest" "$generation_manifest"
  fi
}

if [[ -n "$fetched_ref" ]]; then
  missing_asset=""
  if ! git_ref_has_complete_set "$fetched_ref"; then
    echo "error: fetched website-assets is incomplete; missing $missing_asset" >&2
    exit 1
  fi
  fetched_stage="$stage_root/fetched"
  if ! stage_git_ref "$fetched_ref" "$fetched_stage"; then
    echo "error: could not stage the complete fetched website-assets ref" >&2
    exit 1
  fi
  publish_assets "$fetched_stage" "origin/website-assets"
  exit 0
fi

missing_asset=""
local_stage="$stage_root/local"
if git rev-parse --verify --quiet website-assets >/dev/null 2>&1 \
  && git_ref_has_complete_set website-assets \
  && stage_git_ref website-assets "$local_stage"; then
  publish_assets "$local_stage" "local website-assets"
  exit 0
fi

raw_stage="$stage_root/raw"
if stage_raw_assets "$raw_stage"; then
  publish_assets "$raw_stage" "raw.githubusercontent.com"
  exit 0
fi

cached_stage="$stage_root/cached"
if stage_cached_assets "$cached_stage"; then
  echo "warning: could not reach website-assets; keeping verified asset set" >&2
  publish_assets "$cached_stage" "verified local cache"
  exit 0
fi

if [[ -n "${SYNC_ASSETS_ALLOW_PLACEHOLDER:-}" ]]; then
  placeholder_stage="$stage_root/placeholders"
  stage_placeholders "$placeholder_stage"
  echo "warning: website-assets unreachable; generating placeholder set" >&2
  publish_assets "$placeholder_stage" "generated placeholders" placeholder
  exit 0
fi

echo "error: could not sync the complete website-assets set" >&2
echo "       and the local cache is missing or stale." >&2
echo "       Set SYNC_ASSETS_ALLOW_PLACEHOLDER=1 for CI/dev placeholders," >&2
echo "       or publish the complete asset set." >&2
exit 1
