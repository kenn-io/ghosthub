#!/usr/bin/env bash
# Launches Ghosthub against the faux demo environment. App state/config are
# isolated via GHOSTHUB_* env overrides; the SSH host list is overridden for
# this run only through the NSArgumentDomain (old-style plist <hex> data), so
# real hosts never appear and nothing is written to real defaults.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="${GHOSTHUB_DEMO_SCRATCH:-/tmp/ghosthub-demo}"
app="$scratch/app/Ghosthub.app"
bin="$app/Contents/MacOS/Ghosthub"

# shellcheck source=SCRIPTDIR/scratch-guard.sh
source "$demo_root/scratch-guard.sh"
demo_scratch_guard "$scratch"
[[ -f "$scratch/.ghosthub-demo-scratch" ]] || { echo "error: run stage.sh first" >&2; exit 1; }
[[ -x "$bin" ]] || { echo "error: staged app copy not found; run stage.sh" >&2; exit 1; }
[[ -d "$scratch/home" ]] || { echo "error: run stage.sh first" >&2; exit 1; }

hosts_json='[{"configKey":"gpu-01","name":"gpu-01","platform":"linux",'
hosts_json+='"sshDestination":"ghosthub-demo-remote"}]'
hosts_hex="$(printf '%s' "$hosts_json" | xxd -p | tr -d '\n')"

# shellcheck source=SCRIPTDIR/process.sh
source "$demo_root/process.sh"
pid_record="$scratch/app.pid"
demo_stop_retained_launches "$scratch" "$bin"
demo_stop_recorded_process "$pid_record" "$bin"
launch_dir="$(mktemp -d "$scratch/.launch.XXXXXX")"
launch_record="$launch_dir/app.pid"
publication_lock_held=""

# Install cleanup before LaunchServices can create the application. launch.swift
# either publishes its exact NSRunningApplication PID or terminates it itself.
cleanup_launched_app() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$publication_lock_held" ]]; then
    demo_release_process_record_lock "$pid_record" || status=1
    publication_lock_held=""
  fi
  if [[ -e "$launch_record" || -L "$launch_record" ]]; then
    demo_remove_matching_process_record \
      "$launch_record" "$pid_record" || status=1
    demo_stop_recorded_process "$launch_record" "$bin" || status=1
  fi
  rmdir "$launch_dir" 2>/dev/null || status=1
  exit "$status"
}
trap cleanup_launched_app EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

demo_acquire_process_record_lock "$pid_record"
publication_lock_held=1
/usr/bin/swift "$demo_root/launch.swift" \
  "$app" "$bin" "$launch_record" "$pid_record" "$hosts_hex" \
  "$demo_root" "$scratch" "${SSH_AUTH_SOCK:-}"
demo_release_process_record_lock "$pid_record"
publication_lock_held=""
demo_pid="$(demo_require_recorded_process "$launch_record" "$bin")"
published_pid="$(demo_require_recorded_process "$pid_record" "$bin")"
[[ "$published_pid" == "$demo_pid" ]] || {
  echo "error: demo PID record does not match launched application" >&2
  exit 1
}
trap - EXIT HUP INT TERM
rm -f "$launch_record"
rmdir "$launch_dir"
echo "Ghosthub demo instance launched (pid $demo_pid)."
