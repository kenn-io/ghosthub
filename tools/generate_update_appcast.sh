#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

APP_NAME="${GHOSTHUB_APP:-Ghosthub}"
RELEASE_ROOT="${RELEASE_ROOT:-dist/release}"
RELEASE_VERSION_FILE="${RELEASE_VERSION_FILE:-RELEASE_VERSION}"
DEFAULT_RELEASE_VERSION="$(tr -d '[:space:]' < "$RELEASE_VERSION_FILE")"
RELEASE_APP_VERSION="${RELEASE_APP_VERSION:-$DEFAULT_RELEASE_VERSION}"
RELEASE_ARCH="${RELEASE_ARCH:-$(uname -m)}"
RELEASE_DMG_NAME="${RELEASE_DMG_NAME:-${APP_NAME}_${RELEASE_APP_VERSION}_macos_${RELEASE_ARCH}.dmg}"
RELEASE_APP_PATH="${RELEASE_APP_PATH:-$RELEASE_ROOT/${APP_NAME}.app}"
RELEASE_REPOSITORY="${RELEASE_REPOSITORY:-kenn-io/ghosthub}"
CHANGELOG_PATH="${CHANGELOG_PATH:-CHANGELOG.md}"

if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  RELEASE_TAG="${GITHUB_REF_NAME}"
else
  RELEASE_TAG="${RELEASE_TAG:-v$RELEASE_APP_VERSION}"
fi
APPCAST_DOWNLOAD_PREFIX="https://github.com/$RELEASE_REPOSITORY/releases/download/$RELEASE_TAG/"
RELEASE_URL="https://github.com/$RELEASE_REPOSITORY/releases/tag/$RELEASE_TAG"
APPCAST_LINK="https://ghosthub.ai"
APPCAST_NOTES_PATH="$RELEASE_ROOT/.stable-release-notes.md"

cleanup_notes() {
  rm -f "$APPCAST_NOTES_PATH"
}
trap cleanup_notes EXIT

uv run --frozen python tools/extract_changelog.py \
  --changelog "$CHANGELOG_PATH" \
  --version "$RELEASE_APP_VERSION" \
  --release-url "$RELEASE_URL" \
  --output "$APPCAST_NOTES_PATH"

export RELEASE_ROOT RELEASE_APP_PATH RELEASE_DMG_NAME
export APPCAST_DOWNLOAD_PREFIX APPCAST_LINK APPCAST_NOTES_PATH
"$SCRIPT_DIR/sign_update_appcast.sh"
