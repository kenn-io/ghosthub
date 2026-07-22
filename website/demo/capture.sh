#!/usr/bin/env bash
# Captures the demo Ghosthub window to a PNG (no drop shadow). Pass an output
# path; defaults to .scratch/hero-raw.png. Requires Screen Recording
# permission for the invoking terminal.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="${GHOSTHUB_DEMO_SCRATCH:-/tmp/ghosthub-demo}"
out="${1:-$scratch/hero-raw.png}"
bin="$scratch/app/Ghosthub.app/Contents/MacOS/Ghosthub"

# shellcheck source=SCRIPTDIR/scratch-guard.sh
source "$demo_root/scratch-guard.sh"
demo_scratch_guard "$scratch"
[[ -f "$scratch/.ghosthub-demo-scratch" ]] || { echo "error: run stage.sh first" >&2; exit 1; }
# Only the exact PID recorded by run.sh counts. The real Ghosthub may be
# running at the same time.
# shellcheck source=SCRIPTDIR/process.sh
source "$demo_root/process.sh"
demo_pid="$(demo_require_recorded_process "$scratch/app.pid" "$bin")"

window_id="$(GHOSTHUB_DEMO_PID="$demo_pid" swift - <<'EOF'
import CoreGraphics
import Foundation

guard let pidText = ProcessInfo.processInfo.environment["GHOSTHUB_DEMO_PID"],
      let demoPID = Int(pidText) else { exit(1) }
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
    as? [[String: Any]] else { exit(1) }
for entry in list {
    guard let pid = entry[kCGWindowOwnerPID as String] as? Int,
          pid == demoPID,
          let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
          let number = entry[kCGWindowNumber as String] as? Int
    else { continue }
    print(number)
    break
}
EOF
)"

if [[ -z "$window_id" ]]; then
  echo "error: no on-screen Ghosthub window found (run run.sh first)" >&2
  exit 1
fi

screencapture -o -l "$window_id" "$out"
echo "captured window $window_id -> $out"
sips -g pixelWidth -g pixelHeight "$out" | tail -2
