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

process_matrix_capture() {
  local raw="$1" destination="$2"
  NODE_PATH="$demo_root/../node_modules" node - "$raw" "$destination" <<'EOF'
const sharp = require("sharp");
(async () => {
  const [raw, destination] = process.argv.slice(2);
  const files = [raw, ...[1, 2, 3, 4, 5].map((index) => `${raw}.${index}`)];
  const metadata = await Promise.all(
    files.map((file) => sharp(file).metadata())
  );
  const width = metadata[0].width;
  const height = metadata[0].height;
  if (width === undefined || height === undefined
      || metadata.some((item) => item.width !== width || item.height !== height)) {
    throw new Error("matrix windows did not capture at one consistent size");
  }
  const gap = 6;
  await sharp({
    create: {
      width: width * 3 + gap * 2,
      height: height * 2 + gap,
      channels: 4,
      background: "#080b0e",
    },
  })
    .composite(files.map((input, index) => ({
      input,
      left: (index % 3) * (width + gap),
      top: Math.floor(index / 3) * (height + gap),
    })))
    .resize({ width: 1800 })
    .png({ compressionLevel: 9 })
    .toFile(destination);
})();
EOF
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

prepare_command_window() {
  local query="$1" create="${2:-true}" select="${3:-palette}"
  if [[ "$create" == "true" ]]; then
    demo_input new-window
    sleep 2
  fi
  demo_input frame "160,145,1200,760"
  sleep 1
  if [[ "$select" == "press" ]]; then
    demo_input press "$query"
  else
    palette "$query"
  fi
  sleep 3
  demo_input sidebar
  sleep 1
}

echo "==> guide: six-window tmux command center"
prepare_command_window "fix-reconnect-backoff" false
prepare_command_window "add-session-filters"
prepare_command_window "scratch" true press
prepare_command_window "docbank-export" true press
prepare_command_window "release-watch" true press
prepare_command_window "test-matrix" true press
matrix_raw="$scratch/screenshots-raw/guide-command-center.png"
"$demo_root/capture.sh" "$matrix_raw" matrix
process_matrix_capture "$matrix_raw" "$out_dir/guide-command-center.png"
sips -g pixelWidth -g pixelHeight \
  "$out_dir/guide-command-center.png" | tail -2

echo "captured website asset set -> $out_dir"
