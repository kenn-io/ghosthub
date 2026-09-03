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
notifications.postNotificationName(
    Notification.Name("com.ghosthub.demo.input"),
    object: pid,
    userInfo: [
        "requestID": requestID,
        "action": action,
        "text": environment["GHOSTHUB_DEMO_TEXT"] ?? "",
        "submit": environment["GHOSTHUB_DEMO_SUBMIT"] ?? "false",
        "expectKind": environment["GHOSTHUB_DEMO_EXPECT_KIND"] ?? "",
    ],
    deliverImmediately: true
)
let deadline = Date(timeIntervalSinceNow: 60)
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
  local mode="${2:-window}"
  local raw="$scratch/screenshots-raw/$name"
  "$demo_root/capture.sh" "$raw" "$mode"
  process_capture "$raw" "$out_dir/$name"
  sips -g pixelWidth -g pixelHeight "$out_dir/$name" | tail -2
}

capture_find() {
  demo_input click "80,820"
  sleep 10
  demo_input expect-window-title "agentsview--add-session-filters"
  demo_input click "600,600"
  sleep 0.5
  palette "find in terminal"
  demo_input find "filters" false "filters"
  sleep 1
  capture_state guide-find.png
  demo_input escape
  sleep 1
}

if [[ "${GHOSTHUB_DEMO_FIND_ONLY:-}" == "1" ]]; then
  echo "==> guide: active-pane Find"
  capture_find
  echo "captured active-pane Find website asset -> $out_dir"
  exit 0
fi

if [[ "${GHOSTHUB_DEMO_ALWAYS_LIVE_PREVIEW_ONLY:-}" == "1" ]]; then
  echo "==> guide: Always Live tmux session previews"
  sleep 1
  capture_state guide-session-previews.png
  echo "captured Always Live website asset -> $out_dir"
  exit 0
fi

process_matrix_capture() {
  local raw="$1" destination="$2"
  local temporary
  temporary="$(mktemp "$destination.tmp.XXXXXX")"
  if ! NODE_PATH="$demo_root/../node_modules" \
      node - "$raw" "$temporary" <<'EOF'
const sharp = require("sharp");
(async () => {
  const [raw, destination] = process.argv.slice(2);
  const files = [raw, ...[1, 2, 3].map((index) => `${raw}.${index}`)];
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
      width: width * 2 + gap,
      height: height * 2 + gap,
      channels: 4,
      background: "#080b0e",
    },
  })
    .composite(files.map((input, index) => ({
      input,
      left: (index % 2) * (width + gap),
      top: Math.floor(index / 2) * (height + gap),
    })))
    .resize({ width: 1800 })
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

capture_project_removal() {
  demo_input click "32,489"
  sleep 1
  demo_input click "32,450"
  sleep 1
  demo_input click "300,412"
  sleep 1
  capture_state guide-project-removal.png
  demo_input escape
  sleep 1
  demo_input click "32,450"
  sleep 1
  demo_input click "32,489"
  sleep 1
}

capture_worktree_window_counts() {
  # Collapse Zellij, then expand Projects and the synthetic ghosthub project.
  # These disclosure positions are stable at the fixed demo window size.
  demo_input click "32,489"
  sleep 0.5
  demo_input click "32,450"
  sleep 0.5
  demo_input click "32,412"
  sleep 1
  capture_state guide-worktree-window-counts.png
  # Restore the initial disclosure state for the remaining guide captures.
  demo_input click "32,412"
  sleep 0.5
  demo_input click "32,450"
  sleep 0.5
  demo_input click "32,489"
  sleep 0.5
}

capture_window_title() {
  demo_input rename-window
  sleep 1
  demo_input expect-sheet
  capture_state guide-window-title.png
  demo_input escape
  sleep 1
}

capture_host_settings() {
  palette "Open Hosts Settings" true sheet
  sleep 2
  echo "==> guide: selective Tailscale import"
  # The Settings sheet is fixed at 1040×744. SwiftUI does not expose this
  # toolbar button as a pressable node on every supported macOS build.
  demo_input click-sheet "396,634"
  sleep 2
  capture_state guide-tailscale-import.png
  dismiss_sheet
  # Bring the Verification actions above the settings toolbar. The Hosts
  # detail is taller than the fixed demo sheet, so its initial top position
  # clips those controls in the capture even though they are scrollable.
  demo_input scroll-detail "120"
  sleep 1
  capture_state guide-hosts.png
  dismiss_sheet
}

if [[ "${GHOSTHUB_DEMO_WINDOW_TITLE_ONLY:-}" == "1" ]]; then
  echo "==> guide: editable workspace title"
  capture_window_title
  exit 0
fi

if [[ "${GHOSTHUB_DEMO_WORKTREE_COUNTS_ONLY:-}" == "1" ]]; then
  echo "==> guide: worktree window counts"
  capture_worktree_window_counts
  exit 0
fi

if [[ "${GHOSTHUB_DEMO_PROJECT_REMOVAL_ONLY:-}" == "1" ]]; then
  echo "==> guide: project removal"
  capture_project_removal
  exit 0
fi

if [[ "${GHOSTHUB_DEMO_EXE_ONLY:-}" == "1" ]]; then
  echo "==> guide: exe.dev integration settings"
  palette "Open Integrations Settings" true sheet
  sleep 2
  capture_state guide-exe-dev.png
  echo "captured exe.dev website asset -> $out_dir"
  exit 0
fi

if [[ "${GHOSTHUB_DEMO_TAILSCALE_ONLY:-}" == "1" ]]; then
  echo "==> guide: remote host settings"
  capture_host_settings
  echo "captured Tailscale import website asset -> $out_dir"
  exit 0
fi

if [[ "${GHOSTHUB_DEMO_TABS_ONLY:-}" != "1" &&
      "${GHOSTHUB_DEMO_COMMAND_CENTER_ONLY:-}" != "1" ]]; then
echo "==> controller: unmatched palette commands fail validation"
unmatched_command="__ghosthub_missing_command__"
unmatched_error="$scratch/unmatched-command.error"
if palette "$unmatched_command" \
    2>"$unmatched_error"; then
  echo "error: unmatched command unexpectedly passed palette validation" >&2
  exit 1
fi
demo_input escape

echo "==> guide: worktree window counts"
capture_worktree_window_counts

echo "==> guide: project removal"
capture_project_removal

echo "==> guide: editable workspace title"
capture_window_title

echo "==> hero: active coding-agent worktree"
palette "fix-reconnect-backoff"
sleep 5
# The Projects disclosure control is deliberately compact. Its rendered
# position is stable because the demo window has a fixed 1600×1000 frame,
# while SwiftUI does not expose it as a pressable node on every supported
# macOS build. Leave the default-expanded Herdr group open above it. The
# controller uses AppKit's bottom-left coordinate origin.
demo_input click "32,489"
sleep 0.5
capture_state hero.png

echo "==> guide: ordinary worktree session"
palette "add-session-filters"
sleep 4
# The hero capture collapses the local Zellij group to keep its terminal
# content prominent. Reopen it, attach to a synthetic Zellij session, and
# leave Tmux and Herdr visible as peer groups while the palette names the
# available Zellij actions. AppKit uses a bottom-left coordinate origin.
demo_input click "32,489"
palette "docs-preview"
sleep 2
palette "Zellij" false
capture_state guide-sessions.png
demo_input escape
# Restore the compact disclosure state used by the later fixed-size captures.
demo_input click "32,489"
sleep 0.5

echo "==> guide: active-pane Find"
capture_find

if [[ "${GHOSTHUB_DEMO_SKIP_SESSION_PREVIEWS:-}" != "1" ]]; then
  echo "==> guide: opened tmux session previews"
  palette "add-session-filters"
  sleep 3
  palette "scratch"
  sleep 3
  palette "add-session-filters"
  sleep 3
  # The demo window is fixed at 1600x1000. SwiftUI does not expose this
  # disclosure button to the injected accessibility tree, so click the stable
  # scratch-row chevron in window coordinates.
  demo_input click "31,746"
  sleep 5
  demo_input expect-text "Live"
  capture_state guide-session-previews.png
  # Keep later settings and palette captures focused on their own workflows.
  demo_input click "31,746"
  sleep 0.5
fi

echo "==> guide: remote host settings"
capture_host_settings

echo "==> guide: existing branch picker"
palette "fix-reconnect-backoff"
sleep 2
palette "New Worktree in ghosthub" true sheet
sleep 2
capture_state guide-worktree.png
dismiss_sheet

echo "==> guide: Quick Launch"
palette "reconnect" false
capture_state guide-quick-launch.png
dismiss_sheet

echo "==> guide: appearance settings"
palette "Open Appearance Settings" true sheet
sleep 2
capture_state guide-terminal.png
dismiss_sheet
fi

expected_window_title() {
  case "$1" in
    fix-reconnect-backoff) printf '%s\n' 'ghosthub / fix-reconnect-backoff' ;;
    add-session-filters) printf '%s\n' 'agentsview / add-session-filters' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

prepare_command_window() {
  local query="$1" create="${2:-true}" select="${3:-palette}"
  if [[ "$create" == "true" ]]; then
    demo_input new-window
    sleep 2
  fi
  demo_input frame "160,145,1200,760"
  sleep 1
  if [[ "$select" == "row" ]]; then
    case "$query" in
      add-session-filters)
        if [[ "${GHOSTHUB_DEMO_COMMAND_CENTER_ONLY:-}" == "1" ]]; then
          demo_input click "32,249"
          sleep 0.5
        fi
        demo_input click "32,165"
        sleep 0.5
        demo_input click "80,95"
        ;;
      docbank-export) demo_input click "80,603" ;;
      release-watch) demo_input click "80,558" ;;
      scratch) demo_input click "80,515" ;;
      test-matrix) demo_input click "80,470" ;;
      *)
        echo "error: no fixed demo row for $query" >&2
        return 1
        ;;
    esac
  elif [[ "$select" == "press" ]]; then
    demo_input press "$query"
  elif [[ "$select" == "palette" ]]; then
    palette "$query"
  fi
  sleep 3
  demo_input expect-window-title "$(expected_window_title "$query")"
  demo_input hide-sidebar
}

if [[ "${GHOSTHUB_DEMO_TABS_ONLY:-}" != "1" ]]; then
  echo "==> guide: four-window tmux command center"
  if [[ "${GHOSTHUB_DEMO_COMMAND_CENTER_ONLY:-}" == "1" ]]; then
    prepare_command_window "fix-reconnect-backoff" false palette
  else
    prepare_command_window "fix-reconnect-backoff" false none
  fi
  prepare_command_window "scratch" true row
  prepare_command_window "docbank-export" true row
  prepare_command_window "release-watch" true row
  matrix_raw="$scratch/screenshots-raw/guide-command-center.png"
  "$demo_root/capture.sh" "$matrix_raw" matrix
  process_matrix_capture "$matrix_raw" "$out_dir/guide-command-center.png"
  sips -g pixelWidth -g pixelHeight \
    "$out_dir/guide-command-center.png" | tail -2

  if [[ "${GHOSTHUB_DEMO_COMMAND_CENTER_ONLY:-}" == "1" ]]; then
    echo "captured command-center website asset -> $out_dir"
    exit 0
  fi
fi

prepare_command_tab() {
  local query="$1" create="${2:-true}"
  if [[ "$create" == "true" ]]; then
    demo_input new-tab
    sleep 2
  fi
  palette "$query"
  sleep 3
  demo_input expect-window-title "$(expected_window_title "$query")"
  demo_input hide-sidebar
}

echo "==> guide: six-tab tmux workspace"
demo_input new-window
sleep 2
demo_input frame "110,145,1500,820"
sleep 1
# Palette commands are scoped to the controlled workspace, so tab selection
# stays independent of every command-center window already on screen.
prepare_command_tab "fix-reconnect-backoff" false
prepare_command_tab "add-session-filters"
prepare_command_tab "scratch"
prepare_command_tab "docbank-export"
prepare_command_tab "release-watch"
prepare_command_tab "test-matrix"
capture_state guide-native-tabs.png exact

if [[ "${GHOSTHUB_DEMO_TABS_ONLY:-}" == "1" ]]; then
  echo "captured native-tabs website asset -> $out_dir"
  exit 0
fi

echo "==> guide: passive session activity indicator"
# Every session above is warm from its earlier attachment. Drive fresh
# scrollback into the unselected scratch session on the demo socket only,
# then wait out one quiet-interval resample (20s) so its sidebar row shows
# the accent activity indicator while add-session-filters stays selected.
demo_input new-window
sleep 2
demo_input frame
sleep 1
palette "add-session-filters"
sleep 3
demo_tmux_socket="$scratch/tmux/tmux-$(id -u)/default"
tmux -S "$demo_tmux_socket" send-keys -t '=scratch:' \
  'clear; for f in vault index threads search; do printf "compacting %s… done\n" "$f"; done; seq 1 40 | sed "s/^/segment /"' Enter
sleep 24
capture_state guide-session-activity.png

echo "captured website asset set -> $out_dir"
