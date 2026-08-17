#!/usr/bin/env bash
# Asks the injected demo controller to capture its own composited window to a
# PNG (no drop shadow). Pass an output path; defaults to
# .scratch/hero-raw.png. This stays exact-PID scoped and does not require
# Screen Recording permission for the invoking terminal.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="${GHOSTHUB_DEMO_SCRATCH:-/tmp/ghosthub-demo}"
out="${1:-$scratch/hero-raw.png}"
mode="${2:-window}"
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
if [[ "$mode" == "matrix" ]]; then
  for index in 1 2 3; do
    rm -f "$out.$index" "$out.$index.tmp"
  done
fi
GHOSTHUB_DEMO_PID="$demo_pid" \
  GHOSTHUB_DEMO_CAPTURE_OUT="$out" \
  GHOSTHUB_DEMO_CAPTURE_MODE="$mode" \
  swift - <<'EOF'
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let pid = environment["GHOSTHUB_DEMO_PID"],
      let output = environment["GHOSTHUB_DEMO_CAPTURE_OUT"]
else { exit(1) }
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.ghosthub.demo.capture"),
    object: pid,
    userInfo: [
        "path": output,
        "mode": environment["GHOSTHUB_DEMO_CAPTURE_MODE"] ?? "window",
    ],
    deliverImmediately: true
)
EOF

capture_complete() {
  [[ -s "$out" ]] || return 1
  [[ "$mode" != "matrix" ]] && return 0
  local index
  for index in 1 2 3; do
    [[ -s "$out.$index" ]] || return 1
  done
}

for _ in $(seq 1 100); do
  capture_complete && break
  sleep 0.1
done
if ! capture_complete; then
  echo "error: demo process did not produce a window capture" >&2
  exit 1
fi

if [[ "$mode" == "matrix" ]]; then
  echo "captured four-window demo matrix from process $demo_pid -> $out{,.1...3}"
else
  echo "captured demo process $demo_pid -> $out"
  sips -g pixelWidth -g pixelHeight "$out" | tail -2
fi
