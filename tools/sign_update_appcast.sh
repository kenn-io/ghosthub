#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

: "${RELEASE_ROOT:?RELEASE_ROOT is required}"
: "${RELEASE_APP_PATH:?RELEASE_APP_PATH is required}"
: "${RELEASE_DMG_NAME:?RELEASE_DMG_NAME is required}"
: "${APPCAST_DOWNLOAD_PREFIX:?APPCAST_DOWNLOAD_PREFIX is required}"
: "${APPCAST_LINK:?APPCAST_LINK is required}"
: "${APPCAST_NOTES_PATH:?APPCAST_NOTES_PATH is required}"

SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$(dirname "$SPARKLE_GENERATE_APPCAST")/sign_update}"
SPARKLE_DERIVE_PUBLIC_KEY="${SPARKLE_DERIVE_PUBLIC_KEY:-tools/derive_sparkle_public_key.swift}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_ED_PRIVATE_KEY="${SPARKLE_ED_PRIVATE_KEY:-}"
RELEASE_DMG_PATH="$RELEASE_ROOT/$RELEASE_DMG_NAME"
INFO_PLIST="$RELEASE_APP_PATH/Contents/Info.plist"
EXPECTED_URL="${APPCAST_DOWNLOAD_PREFIX}${RELEASE_DMG_NAME}"
DMG_STEM="${RELEASE_DMG_NAME%.dmg}"
GENERATOR_NOTES_PATH="$RELEASE_ROOT/$DMG_STEM.md"

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY must contain the reviewed public key." >&2
  exit 1
fi
if [[ -z "$SPARKLE_ED_PRIVATE_KEY" ]]; then
  echo "SPARKLE_ED_PRIVATE_KEY must contain the private signing key." >&2
  exit 1
fi
if [[ ! -x "$SPARKLE_GENERATE_APPCAST" ]]; then
  echo "Sparkle generate_appcast is missing: $SPARKLE_GENERATE_APPCAST" >&2
  exit 1
fi
if [[ ! -f "$SPARKLE_DERIVE_PUBLIC_KEY" ]]; then
  echo "Sparkle public-key derivation tool is missing: $SPARKLE_DERIVE_PUBLIC_KEY" >&2
  exit 1
fi
if [[ ! -d "$RELEASE_APP_PATH" ]]; then
  echo "Release app is missing: $RELEASE_APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$RELEASE_DMG_PATH" ]]; then
  echo "Release DMG is missing: $RELEASE_DMG_PATH" >&2
  exit 1
fi
if [[ ! -f "$APPCAST_NOTES_PATH" ]]; then
  echo "Release notes are missing: $APPCAST_NOTES_PATH" >&2
  exit 1
fi

EMBEDDED_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")"
if [[ "$EMBEDDED_PUBLIC_KEY" != "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "The protected Sparkle public key does not match the app bundle." >&2
  exit 1
fi

if [[ -x "$SPARKLE_DERIVE_PUBLIC_KEY" ]]; then
  DERIVED_PUBLIC_KEY="$(
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" \
      | SPARKLE_SIGN_UPDATE="$SPARKLE_SIGN_UPDATE" "$SPARKLE_DERIVE_PUBLIC_KEY"
  )"
else
  DERIVED_PUBLIC_KEY="$(
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" \
      | SPARKLE_SIGN_UPDATE="$SPARKLE_SIGN_UPDATE" swift "$SPARKLE_DERIVE_PUBLIC_KEY"
  )"
fi
if [[ "$DERIVED_PUBLIC_KEY" != "$EMBEDDED_PUBLIC_KEY" ]]; then
  echo "The protected Sparkle private key does not match the app bundle." >&2
  exit 1
fi

cleanup_notes() {
  rm -f "$GENERATOR_NOTES_PATH"
}
trap cleanup_notes EXIT
cp -f "$APPCAST_NOTES_PATH" "$GENERATOR_NOTES_PATH"

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" \
  | "$SPARKLE_GENERATE_APPCAST" \
      --ed-key-file - \
      --download-url-prefix "$APPCAST_DOWNLOAD_PREFIX" \
      --link "$APPCAST_LINK" \
      --embed-release-notes \
      --maximum-versions 1 \
      --maximum-deltas 0 \
      "$RELEASE_ROOT"

APPCAST_PATH="$RELEASE_ROOT/appcast.xml"
xmllint --noout "$APPCAST_PATH"
grep -Fq 'sparkle:edSignature=' "$APPCAST_PATH"
grep -Fq '<!-- sparkle-signatures:' "$APPCAST_PATH"
uv run --frozen python tools/verify_update_appcast.py \
  --appcast "$APPCAST_PATH" \
  --info-plist "$INFO_PLIST" \
  --expected-url "$EXPECTED_URL"

printf 'Signed Sparkle appcast: %s\n' "$APPCAST_PATH"
