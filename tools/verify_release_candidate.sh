#!/bin/sh
# Verifies a downloaded Ghosthub release candidate the way a new user's Mac
# sees it: checksums, Gatekeeper on a quarantined DMG, the notarization
# ticket, the app signature and identity, its version, and the bundled kwt.
# Run it on a Mac that has never built Ghosthub.
#
# Usage: verify_release_candidate.sh <artifact-directory> <version>
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <artifact-directory> <version>" >&2
    exit 64
fi
artifacts=$1
version=$2
dmg="Ghosthub_${version}_macos_arm64.dmg"
team_id=2YMZH84KR8
bundle_id=com.ghosthub

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cd "$artifacts"
[ -f "$dmg" ] || fail "$dmg is missing from $artifacts"

shasum -a 256 -c "$dmg.sha256" || fail "$dmg.sha256 does not match"
shasum -a 256 -c SHA256SUMS || fail "SHA256SUMS does not match"

# A browser download carries this attribute; Gatekeeper then evaluates the
# DMG and anything run from it as a new user's Mac would.
xattr -w com.apple.quarantine \
    "0081;$(printf '%x' "$(date +%s)");Safari;" "$dmg"

stapler validate "$dmg" || fail "the DMG has no valid notarization ticket"
spctl --assess --type open --context context:primary-signature -vv "$dmg" \
    2>&1 | tee /dev/stderr | grep -q "source=Notarized Developer ID" \
    || fail "Gatekeeper does not accept the DMG as notarized"

mountpoint=$(mktemp -d)
cleanup() {
    hdiutil detach -quiet "$mountpoint" 2>/dev/null || true
    rmdir "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mountpoint" "$dmg"
app="$mountpoint/Ghosthub.app"
[ -d "$app" ] || fail "the DMG does not contain Ghosthub.app"

codesign --verify --deep --strict -vv "$app" \
    || fail "Ghosthub.app fails strict code-signature verification"
spctl --assess --type execute -vv "$app" 2>&1 | tee /dev/stderr \
    | grep -q "source=Notarized Developer ID" \
    || fail "Gatekeeper does not accept Ghosthub.app as notarized"

signature=$(codesign -dv "$app" 2>&1)
printf '%s\n' "$signature" | grep -qx "Identifier=$bundle_id" \
    || fail "the bundle identifier is not $bundle_id"
printf '%s\n' "$signature" | grep -qx "TeamIdentifier=$team_id" \
    || fail "the Developer ID team is not $team_id"

plist="$app/Contents/Info.plist"
app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
[ "$app_version" = "$version" ] \
    || fail "the app reports version $app_version, expected $version"

"$app/Contents/Helpers/kwt" --version \
    || fail "the bundled kwt helper does not run"

echo "PASS: Ghosthub $version candidate verified"
