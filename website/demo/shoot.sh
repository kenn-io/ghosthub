#!/usr/bin/env bash
# Drives the running demo instance to the hero state and captures it:
# activate by pid (the real Ghosthub may be running alongside), select the
# agent session through the command palette, redraw the git log pane at the
# attached client size, then screenshot the window via capture.sh.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="${GHOSTHUB_DEMO_SCRATCH:-/tmp/ghosthub-demo}"
out="${1:-$scratch/hero-raw.png}"
bin="$scratch/app/Ghosthub.app/Contents/MacOS/Ghosthub"

# shellcheck source=SCRIPTDIR/scratch-guard.sh
source "$demo_root/scratch-guard.sh"
demo_scratch_guard "$scratch"
[[ -f "$scratch/.ghosthub-demo-scratch" ]] || { echo "error: run stage.sh first" >&2; exit 1; }
# shellcheck source=SCRIPTDIR/process.sh
source "$demo_root/process.sh"
demo_pid="$(demo_require_recorded_process "$scratch/app.pid" "$bin")"

# NSRunningApplication targets the exact process; activating "Ghosthub" by
# name or System Events frontmost routes to the real app instead.
GHOSTHUB_DEMO_PID="$demo_pid" swift - <<'EOF'
import AppKit
let pid = Int32(ProcessInfo.processInfo.environment["GHOSTHUB_DEMO_PID"]!)!
guard let app = NSRunningApplication(processIdentifier: pid) else { exit(1) }
app.activate(options: [.activateIgnoringOtherApps])
Thread.sleep(forTimeInterval: 1.0)
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
    FileHandle.standardError.write(Data("demo app did not become frontmost\n".utf8))
    exit(1)
}
EOF

osascript <<'EOF'
tell application "System Events"
  keystroke "p" using {command down, shift down}
  delay 0.8
  keystroke "fix-reconnect"
  delay 0.8
  key code 36
end tell
EOF

sleep 5
"$demo_root/capture.sh" "$out"
