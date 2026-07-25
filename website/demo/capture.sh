#!/usr/bin/env bash
# Asks the injected demo controller to capture its own composited window to a
# PNG (no drop shadow). Pass an output path; defaults to
# .scratch/hero-raw.png. This stays exact-PID scoped and does not require
# Screen Recording permission for the invoking terminal.
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

rm -f "$out" "$out.tmp"
GHOSTHUB_DEMO_PID="$demo_pid" GHOSTHUB_DEMO_CAPTURE_OUT="$out" swift - <<'EOF'
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let pid = environment["GHOSTHUB_DEMO_PID"],
      let output = environment["GHOSTHUB_DEMO_CAPTURE_OUT"]
else { exit(1) }
DistributedNotificationCenter.default().post(
    name: Notification.Name("com.ghosthub.demo.capture"),
    object: pid,
    userInfo: ["path": output]
)
EOF

for _ in $(seq 1 50); do
  [[ -s "$out" ]] && break
  sleep 0.1
done
if [[ ! -s "$out" ]]; then
  echo "error: demo process did not produce a window capture" >&2
  exit 1
fi

echo "captured demo process $demo_pid -> $out"
sips -g pixelWidth -g pixelHeight "$out" | tail -2
