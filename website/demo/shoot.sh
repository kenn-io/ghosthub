#!/usr/bin/env bash
# Drives the running isolated demo through every website screenshot state,
# captures the exact demo process with native macOS chrome, and writes web-ready
# 1600px PNGs. The real Ghosthub may run alongside it.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="${GHOSTHUB_DEMO_SCRATCH:-/tmp/ghosthub-demo}"
out_dir="${1:-$scratch/screenshots}"
bin="$scratch/app/Ghosthub.app/Contents/MacOS/Ghosthub"

# shellcheck source=SCRIPTDIR/scratch-guard.sh
source "$demo_root/scratch-guard.sh"
demo_scratch_guard "$scratch"
[[ -f "$scratch/.ghosthub-demo-scratch" ]] || { echo "error: run stage.sh first" >&2; exit 1; }
demo_private_directory_prepare \
  "$out_dir" "screenshot output" "replace screenshots"
# shellcheck source=SCRIPTDIR/process.sh
source "$demo_root/process.sh"
demo_pid="$(demo_require_recorded_process "$scratch/app.pid" "$bin")"
mkdir -p "$scratch/screenshots-raw"

demo_input() {
  local action="$1" text="${2:-}" submit="${3:-false}"
  local expect_kind="${4:-}"
  GHOSTHUB_DEMO_PID="$demo_pid" \
    GHOSTHUB_DEMO_ACTION="$action" \
    GHOSTHUB_DEMO_TEXT="$text" \
    GHOSTHUB_DEMO_SUBMIT="$submit" \
    GHOSTHUB_DEMO_EXPECT_KIND="$expect_kind" \
    swift - <<'EOF'
import Foundation
import Darwin

let environment = ProcessInfo.processInfo.environment
guard let pid = environment["GHOSTHUB_DEMO_PID"],
      let action = environment["GHOSTHUB_DEMO_ACTION"]
else { exit(1) }

final class Acknowledgement: NSObject {
    let requestID: String
    var result: Bool?
    var message = ""

    init(requestID: String) {
        self.requestID = requestID
    }

    @objc func receive(_ notification: Notification) {
        guard notification.userInfo?["requestID"] as? String == requestID else {
            return
        }
        result = notification.userInfo?["success"] as? Bool ?? false
        message = notification.userInfo?["message"] as? String ?? ""
    }
}

let requestID = UUID().uuidString
let acknowledgement = Acknowledgement(requestID: requestID)
let notifications = DistributedNotificationCenter.default()
notifications.addObserver(
    acknowledgement,
    selector: #selector(Acknowledgement.receive(_:)),
    name: Notification.Name("com.ghosthub.demo.input.ack"),
    object: pid
)
notifications.post(
    name: Notification.Name("com.ghosthub.demo.input"),
    object: pid,
    userInfo: [
        "requestID": requestID,
        "action": action,
        "text": environment["GHOSTHUB_DEMO_TEXT"] ?? "",
        "submit": environment["GHOSTHUB_DEMO_SUBMIT"] ?? "false",
        "expectKind": environment["GHOSTHUB_DEMO_EXPECT_KIND"] ?? "",
    ]
)
let deadline = Date(timeIntervalSinceNow: 15)
while acknowledgement.result == nil && Date() < deadline {
    RunLoop.current.run(
        mode: .default,
        before: Date(timeIntervalSinceNow: 0.05)
    )
}
notifications.removeObserver(acknowledgement)
guard let succeeded = acknowledgement.result else {
    fputs("error: demo action \(action) timed out (\(requestID))\n", stderr)
    exit(1)
}
guard succeeded else {
    fputs(
        "error: demo action \(action) failed: \(acknowledgement.message) "
        + "(\(requestID))\n",
        stderr
    )
    exit(1)
}
EOF
}

demo_ready=""
ready_error="$scratch/controller-ready.error"
for _ in $(seq 1 20); do
  if demo_input frame 2>"$ready_error"; then
    demo_ready=1
    break
  fi
  sleep 0.5
done
if [[ -z "$demo_ready" ]]; then
  sed -n '1,5p' "$ready_error" >&2
  echo "error: demo controller never reported a ready workspace window" >&2
  exit 1
fi
# Allow both local inventory and the isolated SSH host probe to settle before
# the first capture so the full fleet is present in every sidebar.
sleep 10

palette() {
  local query="$1" submit="${2:-true}"
  local result="${3:-selection}"
  local expectation="palette-closed"
  if [[ "$submit" != "true" ]]; then
    expectation="palette-open"
  elif [[ "$result" == "sheet" ]]; then
    expectation="palette-replaced"
  fi
  if ! demo_input palette "$query" "$submit" "$expectation"; then
    return 1
  fi
  sleep 1.5
}

dismiss_sheet() {
  demo_input escape
  sleep 1
}

process_capture() {
  local raw="$1" destination="$2"
  local temporary
  temporary="$(mktemp "$destination.tmp.XXXXXX")"
  if ! NODE_PATH="$demo_root/../node_modules" \
      node - "$raw" "$temporary" <<'EOF'
const sharp = require("sharp");
(async () => {
  const [raw, destination] = process.argv.slice(2);
  const image = sharp(raw);
  const metadata = await image.metadata();
  if (metadata.width === undefined || metadata.height === undefined) {
    throw new Error(`could not read screenshot dimensions: ${raw}`);
  }
  await image
    .resize({ width: 1600 })
    .png({ compressionLevel: 9 })
    .toFile(destination);
})();
EOF
  then
    rm -f "$temporary"
    return 1
  fi
  mv -f "$temporary" "$destination"
}

capture_state() {
  local name="$1"
  local raw="$scratch/screenshots-raw/$name"
  "$demo_root/capture.sh" "$raw"
  process_capture "$raw" "$out_dir/$name"
  sips -g pixelWidth -g pixelHeight "$out_dir/$name" | tail -2
}

echo "==> controller: unmatched palette commands fail validation"
unmatched_command="__ghosthub_missing_command__"
unmatched_error="$scratch/unmatched-command.error"
if palette "$unmatched_command" \
    2>"$unmatched_error"; then
  echo "error: unmatched command unexpectedly passed palette validation" >&2
  exit 1
fi
demo_input escape

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
palette "Open Hosts Settings" true sheet
sleep 2
capture_state guide-hosts.png
dismiss_sheet

echo "==> guide: new worktree"
palette "fix-reconnect-backoff"
sleep 2
palette "New Worktree in ghosthub" true sheet
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
palette "Open Terminal Settings" true sheet
sleep 2
capture_state guide-terminal.png
dismiss_sheet

prepare_command_tab() {
  local query="$1" create="${2:-true}" select="${3:-palette}"
  if [[ "$create" == "true" ]]; then
    demo_input new-tab
    sleep 2
  fi
  demo_input frame "110,145,1500,820"
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

echo "==> guide: six-tab tmux command center"
prepare_command_tab "fix-reconnect-backoff" false
prepare_command_tab "add-session-filters"
prepare_command_tab "scratch" true press
prepare_command_tab "docbank-export" true press
prepare_command_tab "release-watch" true press
prepare_command_tab "test-matrix" true press
capture_state guide-command-center.png

echo "captured website asset set -> $out_dir"
