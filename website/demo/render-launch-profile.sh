#!/usr/bin/env bash
# Renders the real launch-profile sheet offscreen through the UI test target.
# Unlike the full marketing capture workflow, this never launches or activates
# Ghosthub and cannot steal focus from another desktop application.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$demo_root/../.." && pwd)"
output="${1:-/private/tmp/ghosthub-doc-assets/docs-launch-profiles.png}"
output_dir="$(dirname "$output")"

case "$output" in
  "" | / | */ | */. | */..)
    echo "error: output must name a PNG file" >&2
    exit 2
    ;;
esac
[[ "${output##*.}" == "png" ]] || {
  echo "error: output must end in .png" >&2
  exit 2
}
if [[ -e "$output" && ! -f "$output" ]]; then
  echo "error: output exists and is not a regular file: $output" >&2
  exit 2
fi

umask 077
mkdir -p "$output_dir"
temporary="$(mktemp "$output_dir/.docs-launch-profiles.XXXXXX.png")"
cleanup() {
  rm -f "$temporary"
}
trap cleanup EXIT HUP INT TERM

GHOSTHUB_LAUNCH_PROFILE_SCREENSHOT="$temporary" \
  sh "$repo_root/tools/run_swift_tests.sh" \
  swift test --package-path "$repo_root" \
  --filter LaunchProfileScreenshotTests
mv -f "$temporary" "$output"
trap - EXIT HUP INT TERM

sips -g pixelWidth -g pixelHeight "$output" | tail -2
echo "rendered launch profile documentation asset -> $output"
