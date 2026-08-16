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
RELEASE_BUILD_VERSION="${RELEASE_BUILD_VERSION:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
RELEASE_BUNDLE_ID="${RELEASE_BUNDLE_ID:-com.ghosthub}"
# `hdiutil create` fails here when the mounted volume name matches the staged
# top-level `Ghosthub.app` bundle name exactly, so keep the default distinct.
RELEASE_VOLUME_NAME="${RELEASE_VOLUME_NAME:-Ghosthub Installer}"
RELEASE_ARCH="${RELEASE_ARCH:-$(uname -m)}"
RELEASE_DMG_NAME="${RELEASE_DMG_NAME:-${APP_NAME}_${RELEASE_APP_VERSION}_macos_${RELEASE_ARCH}.dmg}"
RELEASE_APP_PATH="${RELEASE_APP_PATH:-$RELEASE_ROOT/${APP_NAME}.app}"
RELEASE_DMG_PATH="${RELEASE_DMG_PATH:-$RELEASE_ROOT/$RELEASE_DMG_NAME}"
DMG_STAGING_DIR="${DMG_STAGING_DIR:-$RELEASE_ROOT/dmg-staging}"
APP_ENTITLEMENTS_PATH="${APP_ENTITLEMENTS_PATH:-Resources/Ghosthub.entitlements}"
KWT_BINARY_PATH="${KWT_BINARY_PATH:-}"
KWT_VERSION="${KWT_VERSION:-}"
KWT_SOURCE_REVISION="${KWT_SOURCE_REVISION:-}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-stable}"
NIGHTLY_SPARKLE_FEED_URL="${NIGHTLY_SPARKLE_FEED_URL:-}"
NIGHTLY_SPARKLE_PUBLIC_ED_KEY="${NIGHTLY_SPARKLE_PUBLIC_ED_KEY:-}"
NIGHTLY_SOURCE_REVISION="${NIGHTLY_SOURCE_REVISION:-}"
NIGHTLY_BUILD_DATE="${NIGHTLY_BUILD_DATE:-}"

APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
APPLE_NOTARY_KEY_FILE="${APPLE_NOTARY_KEY_FILE:-}"
APPLE_NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-${APPLE_API_KEY:-}}"
APPLE_NOTARY_ISSUER="${APPLE_NOTARY_ISSUER:-${APPLE_API_ISSUER:-}}"

release_app_arguments=(
  release-app
  "RELEASE_ROOT=$RELEASE_ROOT"
  "RELEASE_APP_VERSION=$RELEASE_APP_VERSION"
  "RELEASE_BUILD_VERSION=$RELEASE_BUILD_VERSION"
  "RELEASE_BUNDLE_ID=$RELEASE_BUNDLE_ID"
  "RELEASE_CHANNEL=$RELEASE_CHANNEL"
)
if [[ "$RELEASE_CHANNEL" == "nightly" ]]; then
  release_app_arguments+=(
    "NIGHTLY_SPARKLE_FEED_URL=$NIGHTLY_SPARKLE_FEED_URL"
    "NIGHTLY_SPARKLE_PUBLIC_ED_KEY=$NIGHTLY_SPARKLE_PUBLIC_ED_KEY"
    "NIGHTLY_SOURCE_REVISION=$NIGHTLY_SOURCE_REVISION"
    "NIGHTLY_BUILD_DATE=$NIGHTLY_BUILD_DATE"
  )
fi
if [[ -n "$KWT_BINARY_PATH" ]]; then
  release_app_arguments+=("KWT_BINARY_PATH=$KWT_BINARY_PATH")
fi
if [[ -n "$KWT_VERSION" ]]; then
  release_app_arguments+=("KWT_VERSION=$KWT_VERSION")
fi
if [[ -n "$KWT_SOURCE_REVISION" ]]; then
  release_app_arguments+=(
    "KWT_SOURCE_REVISION=$KWT_SOURCE_REVISION"
  )
fi
make "${release_app_arguments[@]}"

xattr -cr "$RELEASE_APP_PATH"

if [[ -n "$APPLE_SIGNING_IDENTITY" ]]; then
  SPARKLE_FRAMEWORK_PATH="$RELEASE_APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ ! -d "$SPARKLE_FRAMEWORK_PATH" ]]; then
    echo "Sparkle framework is missing from the release app." >&2
    exit 1
  fi

  sign_sparkle_component() {
    local path="$1"
    printf 'Codesigning Sparkle component: %s\n' "$path"
    codesign \
      --force \
      --options runtime \
      --preserve-metadata=identifier,entitlements \
      --timestamp \
      --sign "$APPLE_SIGNING_IDENTITY" \
      "$path"
    codesign --verify --strict --verbose=2 "$path"
  }

  sign_sparkle_component \
    "$SPARKLE_FRAMEWORK_PATH/Versions/B/Autoupdate"
  sign_sparkle_component \
    "$SPARKLE_FRAMEWORK_PATH/Versions/B/XPCServices/Downloader.xpc"
  sign_sparkle_component \
    "$SPARKLE_FRAMEWORK_PATH/Versions/B/XPCServices/Installer.xpc"
  sign_sparkle_component \
    "$SPARKLE_FRAMEWORK_PATH/Versions/B/Updater.app"
  sign_sparkle_component "$SPARKLE_FRAMEWORK_PATH"

  KWT_HELPER_PATH="$RELEASE_APP_PATH/Contents/Helpers/kwt"
  printf 'Codesigning kwt helper: %s\n' "$KWT_HELPER_PATH"
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$KWT_HELPER_PATH"
  codesign --verify --strict --verbose=2 "$KWT_HELPER_PATH"

  for target in darwin-amd64 darwin-arm64; do
    REMOTE_KWT_HELPER_PATH="$RELEASE_APP_PATH/Contents/Resources/KwtRemote/$target/kwt"
    printf 'Codesigning remote kwt helper (%s): %s\n' \
      "$target" "$REMOTE_KWT_HELPER_PATH"
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$APPLE_SIGNING_IDENTITY" \
      "$REMOTE_KWT_HELPER_PATH"
    codesign --verify --strict --verbose=2 "$REMOTE_KWT_HELPER_PATH"
  done

  printf 'Codesigning app bundle: %s\n' "$RELEASE_APP_PATH"
  codesign \
    --force \
    --options runtime \
    --entitlements "$APP_ENTITLEMENTS_PATH" \
    --timestamp \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$RELEASE_APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$RELEASE_APP_PATH"
fi

rm -rf "$DMG_STAGING_DIR" "$RELEASE_DMG_PATH"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$RELEASE_APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

printf 'Creating DMG: %s\n' "$RELEASE_DMG_PATH"
hdiutil create \
  -volname "$RELEASE_VOLUME_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$RELEASE_DMG_PATH"

if [[ -n "$APPLE_SIGNING_IDENTITY" ]]; then
  printf 'Codesigning DMG: %s\n' "$RELEASE_DMG_PATH"
  codesign \
    --force \
    --timestamp \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$RELEASE_DMG_PATH"
  codesign --verify --verbose=2 "$RELEASE_DMG_PATH"
fi

if [[ -n "$APPLE_NOTARY_KEY_FILE" || -n "$APPLE_NOTARY_KEY_ID" || -n "$APPLE_NOTARY_ISSUER" ]]; then
  if [[ -z "$APPLE_NOTARY_KEY_FILE" || -z "$APPLE_NOTARY_KEY_ID" || -z "$APPLE_NOTARY_ISSUER" ]]; then
    echo "APPLE_NOTARY_KEY_FILE, APPLE_NOTARY_KEY_ID, and APPLE_NOTARY_ISSUER must all be set to notarize the DMG." >&2
    exit 1
  fi

  printf 'Submitting DMG for notarization: %s\n' "$RELEASE_DMG_PATH"
  NOTARY_RESULT_PATH="$(mktemp "${TMPDIR:-/tmp}/notary-submit.XXXXXX.json")"
  cleanup_notary_result() { rm -f "$NOTARY_RESULT_PATH"; }
  trap cleanup_notary_result EXIT
  xcrun notarytool submit \
    "$RELEASE_DMG_PATH" \
    --key "$APPLE_NOTARY_KEY_FILE" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER" \
    --wait \
    --output-format json \
    > "$NOTARY_RESULT_PATH"

  cat "$NOTARY_RESULT_PATH"

  NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT_PATH" 2>/dev/null || true)"
  NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT_PATH" 2>/dev/null || true)"

  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    printf 'Notarization failed with status: %s\n' "$NOTARY_STATUS" >&2
    if [[ -n "$NOTARY_ID" ]]; then
      printf 'Fetching notarization log for submission: %s\n' "$NOTARY_ID" >&2
      xcrun notarytool log \
        "$NOTARY_ID" \
        --key "$APPLE_NOTARY_KEY_FILE" \
        --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_ISSUER" \
        || true
    fi
    exit 1
  fi

  printf 'Stapling notarization ticket: %s\n' "$RELEASE_DMG_PATH"
  xcrun stapler staple "$RELEASE_DMG_PATH"
  xcrun stapler validate "$RELEASE_DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 \
    "$RELEASE_DMG_PATH"
fi

RELEASE_DMG_DIR="$(dirname "$RELEASE_DMG_PATH")"
RELEASE_DMG_BASENAME="$(basename "$RELEASE_DMG_PATH")"
(
  cd "$RELEASE_DMG_DIR"
  shasum -a 256 "$RELEASE_DMG_BASENAME"
) > "$RELEASE_DMG_PATH.sha256"
rm -rf "$DMG_STAGING_DIR"

printf 'Release app bundle: %s\n' "$RELEASE_APP_PATH"
printf 'Release DMG: %s\n' "$RELEASE_DMG_PATH"
printf 'SHA256 file: %s.sha256\n' "$RELEASE_DMG_PATH"
