#!/usr/bin/env bash
# Drives the running isolated demo through every website screenshot state,
# captures the exact demo process, crops native macOS chrome, and writes
# web-ready 1600px PNGs. The real Ghosthub may run alongside it.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="${GHOSTHUB_DEMO_SCRATCH:-/tmp/ghosthub-demo}"
out_dir="${1:-$scratch/screenshots}"
bin="$scratch/app/Ghosthub.app/Contents/MacOS/Ghosthub"

# shellcheck source=SCRIPTDIR/scratch-guard.sh
source "$demo_root/scratch-guard.sh"
demo_scratch_guard "$scratch"
[[ -f "$scratch/.ghosthub-demo-scratch" ]] || { echo "error: run stage.sh first" >&2; exit 1; }
# shellcheck source=SCRIPTDIR/process.sh
source "$demo_root/process.sh"
demo_pid="$(demo_require_recorded_process "$scratch/app.pid" "$bin")"
mkdir -p "$out_dir" "$scratch/screenshots-raw"

demo_input() {
  local action="$1" text="${2:-}" submit="${3:-false}"
  GHOSTHUB_DEMO_PID="$demo_pid" \
    GHOSTHUB_DEMO_ACTION="$action" \
    GHOSTHUB_DEMO_TEXT="$text" \
    GHOSTHUB_DEMO_SUBMIT="$submit" \
    swift - <<'EOF'
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let pid = environment["GHOSTHUB_DEMO_PID"],
      let action = environment["GHOSTHUB_DEMO_ACTION"]
else { exit(1) }
DistributedNotificationCenter.default().post(
    name: Notification.Name("com.ghosthub.demo.input"),
    object: pid,
    userInfo: [
        "action": action,
        "text": environment["GHOSTHUB_DEMO_TEXT"] ?? "",
        "submit": environment["GHOSTHUB_DEMO_SUBMIT"] ?? "false",
    ]
)
EOF
}

demo_input frame
# Allow both local inventory and the isolated SSH host probe to settle before
# the first capture so the full fleet is present in every sidebar.
sleep 10

palette() {
  local query="$1" submit="${2:-true}"
  demo_input palette "$query" "$submit"
  sleep 1.5
}

dismiss_sheet() {
  demo_input escape
  sleep 1
}

process_capture() {
  local raw="$1" destination="$2"
  NODE_PATH="$demo_root/../node_modules" node - "$raw" "$destination" <<'EOF'
const sharp = require("sharp");
(async () => {
  const [raw, destination] = process.argv.slice(2);
  const image = sharp(raw);
  const metadata = await image.metadata();
  if (metadata.width === undefined || metadata.height === undefined) {
    throw new Error(`could not read screenshot dimensions: ${raw}`);
  }
  const titlebarHeight = 34;
  await image
    .extract({
      left: 0,
      top: titlebarHeight,
      width: metadata.width,
      height: metadata.height - titlebarHeight,
    })
    .resize({ width: 1600 })
    .png({ compressionLevel: 9 })
    .toFile(destination);
})();
EOF
}

capture_state() {
  local name="$1"
  local raw="$scratch/screenshots-raw/$name"
  "$demo_root/capture.sh" "$raw"
  process_capture "$raw" "$out_dir/$name"
  sips -g pixelWidth -g pixelHeight "$out_dir/$name" | tail -2
}

echo "==> hero: active coding-agent worktree"
palette "fix-reconnect-backoff"
sleep 5
demo_input press "Expand Projects"
sleep 0.5
demo_input press "Expand ghosthub"
sleep 0.5
capture_state hero.png

echo "==> guide: ordinary worktree session"
palette "add-session-filters"
sleep 4
demo_input press "Expand agentsview"
sleep 0.5
capture_state guide-sessions.png

echo "==> guide: remote host settings"
palette "Open Hosts Settings"
sleep 2
capture_state guide-hosts.png
dismiss_sheet

echo "==> guide: new worktree"
palette "fix-reconnect-backoff"
sleep 2
palette "New Worktree in ghosthub"
sleep 1
demo_input text "improve-session-search"
sleep 1
capture_state guide-worktree.png
dismiss_sheet

echo "==> guide: Quick Launch"
palette "reconnect" false
capture_state guide-quick-launch.png
dismiss_sheet

echo "==> guide: terminal settings"
palette "Open Terminal Settings"
sleep 2
capture_state guide-terminal.png
dismiss_sheet

echo "captured website asset set -> $out_dir"
