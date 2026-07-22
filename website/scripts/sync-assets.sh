#!/usr/bin/env bash
# Materializes binary assets from the orphan website-assets branch into
# src/assets/. Screenshot binaries live there so refreshes never bloat
# main's history; hero.png is gitignored on main.
#
# Resolution order: git fetch (local dev, CI with credentials), local
# branch, raw.githubusercontent.com (Vercel builds have no usable .git;
# works once the repo is public), pre-existing file. A generated
# placeholder is a last resort and only with SYNC_ASSETS_ALLOW_PLACEHOLDER
# set, so production can never silently deploy without the real asset.
set -euo pipefail
cd "$(dirname "$0")/.."
# hero.png may be the directory's only file; a fresh checkout lacks it.
mkdir -p src/assets

RAW_URL="https://raw.githubusercontent.com/kenn-io/ghosthub/website-assets/hero.png"
# Sidecars distinguish generated placeholders from successfully synced assets.
# The synced marker includes a checksum so stale provenance cannot bless a
# subsequently replaced file.
MARKER="src/assets/hero.png.placeholder"
SYNCED_MARKER="src/assets/hero.png.synced"

record_synced_asset() {
  shasum -a 256 src/assets/hero.png > "$SYNCED_MARKER"
}

asset_is_synced() {
  [[ -f "$SYNCED_MARKER" ]] && shasum -a 256 -c "$SYNCED_MARKER" >/dev/null 2>&1
}

if git fetch --depth=1 origin website-assets 2>/dev/null; then
  git show FETCH_HEAD:hero.png > src/assets/hero.png
  rm -f "$MARKER"
  record_synced_asset
  echo "synced src/assets/hero.png from origin/website-assets"
elif git rev-parse --verify --quiet website-assets >/dev/null 2>&1; then
  git show website-assets:hero.png > src/assets/hero.png
  rm -f "$MARKER"
  record_synced_asset
  echo "synced src/assets/hero.png from local website-assets"
elif curl -fsSL --max-time 30 -o src/assets/hero.png.tmp "$RAW_URL" 2>/dev/null; then
  mv -f src/assets/hero.png.tmp src/assets/hero.png
  rm -f "$MARKER"
  record_synced_asset
  echo "synced src/assets/hero.png from raw.githubusercontent.com"
elif [[ -f src/assets/hero.png && ! -f "$MARKER" ]] && asset_is_synced; then
  echo "warning: could not reach website-assets; keeping existing hero.png" >&2
elif [[ -f src/assets/hero.png && -n "${SYNC_ASSETS_ALLOW_PLACEHOLDER:-}" ]]; then
  echo "warning: could not reach website-assets; keeping placeholder" >&2
  rm -f "$SYNCED_MARKER"
  touch "$MARKER"
elif [[ -n "${SYNC_ASSETS_ALLOW_PLACEHOLDER:-}" ]]; then
  echo "warning: website-assets unreachable; generating placeholder" >&2
  node -e '
    const sharp = require("sharp");
    const svg = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="966">
         <rect width="100%" height="100%" fill="#0d1420"/>
         <text x="50%" y="50%" fill="#5f6870" font-size="28"
               font-family="monospace" text-anchor="middle">
           hero screenshot placeholder
         </text>
       </svg>`
    );
    sharp(svg).png().toFile("src/assets/hero.png");
  '
  rm -f "$SYNCED_MARKER"
  touch "$MARKER"
else
  echo "error: website-assets branch unreachable and src/assets/hero.png" >&2
  echo "       is missing or is a stale placeholder. Set" >&2
  echo "       SYNC_ASSETS_ALLOW_PLACEHOLDER=1 for a placeholder (CI/dev" >&2
  echo "       only), or fetch the branch." >&2
  exit 1
fi
