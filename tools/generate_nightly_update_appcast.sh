#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

APP_NAME="${GHOSTHUB_APP:-Ghosthub}"
RELEASE_ROOT="${RELEASE_ROOT:-.dist/nightly}"
RELEASE_APP_PATH="${RELEASE_APP_PATH:-$RELEASE_ROOT/${APP_NAME}.app}"
RELEASE_DMG_NAME="${RELEASE_DMG_NAME:-}"
NIGHTLY_PUBLIC_BASE_URL="${NIGHTLY_PUBLIC_BASE_URL:-}"
NIGHTLY_SOURCE_SHA="${NIGHTLY_SOURCE_SHA:-}"
NIGHTLY_PREVIOUS_SOURCE_SHA="${NIGHTLY_PREVIOUS_SOURCE_SHA:-}"
NIGHTLY_BUILD_AT="${NIGHTLY_BUILD_AT:-}"
NIGHTLY_BUILD_VERSION="${NIGHTLY_BUILD_VERSION:-}"
NIGHTLY_REPOSITORY="${NIGHTLY_REPOSITORY:-kenn-io/ghosthub}"
NIGHTLY_REPOSITORY_PATH="${NIGHTLY_REPOSITORY_PATH:-$REPO_ROOT}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-}"
GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-}"

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    printf '%s is required.\n' "$name" >&2
    exit 1
  fi
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s must be a positive integer.\n' "$name" >&2
    exit 1
  fi
}

require_value RELEASE_DMG_NAME "$RELEASE_DMG_NAME"
require_value NIGHTLY_PUBLIC_BASE_URL "$NIGHTLY_PUBLIC_BASE_URL"
require_value NIGHTLY_SOURCE_SHA "$NIGHTLY_SOURCE_SHA"
require_value NIGHTLY_BUILD_AT "$NIGHTLY_BUILD_AT"
require_positive_integer NIGHTLY_BUILD_VERSION "$NIGHTLY_BUILD_VERSION"
require_positive_integer GITHUB_RUN_ID "$GITHUB_RUN_ID"
require_positive_integer GITHUB_RUN_ATTEMPT "$GITHUB_RUN_ATTEMPT"
if [[ ! "$NIGHTLY_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "NIGHTLY_SOURCE_SHA must be a full lowercase Git SHA." >&2
  exit 1
fi
if [[ -n "$NIGHTLY_PREVIOUS_SOURCE_SHA" && ! "$NIGHTLY_PREVIOUS_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "NIGHTLY_PREVIOUS_SOURCE_SHA must be a full lowercase Git SHA." >&2
  exit 1
fi

RELEASE_TAG="nightly-${NIGHTLY_BUILD_VERSION}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
APPCAST_DOWNLOAD_PREFIX="${NIGHTLY_PUBLIC_BASE_URL%/}/download/${RELEASE_TAG}/"
APPCAST_LINK="https://github.com/$NIGHTLY_REPOSITORY/commit/$NIGHTLY_SOURCE_SHA"
APPCAST_NOTES_PATH="$RELEASE_ROOT/.nightly-release-notes.md"

cleanup_notes() {
  rm -f "$APPCAST_NOTES_PATH"
}
trap cleanup_notes EXIT

notes_arguments=(
  --repository "$NIGHTLY_REPOSITORY"
  --source-sha "$NIGHTLY_SOURCE_SHA"
  --built-at "$NIGHTLY_BUILD_AT"
  --repo-path "$NIGHTLY_REPOSITORY_PATH"
  --output "$APPCAST_NOTES_PATH"
)
if [[ -n "$NIGHTLY_PREVIOUS_SOURCE_SHA" ]]; then
  notes_arguments+=(--previous-source-sha "$NIGHTLY_PREVIOUS_SOURCE_SHA")
fi
uv run --frozen python tools/nightly_release_notes.py "${notes_arguments[@]}"

export RELEASE_ROOT RELEASE_APP_PATH RELEASE_DMG_NAME
export APPCAST_DOWNLOAD_PREFIX APPCAST_LINK APPCAST_NOTES_PATH
"$SCRIPT_DIR/sign_update_appcast.sh"
