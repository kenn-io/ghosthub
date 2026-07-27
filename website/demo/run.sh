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
demo_stop_recorded_process "$pid_record" "$bin"

env -u TMUX \
  HOME="$scratch/home" \
  ZDOTDIR="$scratch/home" \
  SHELL=/bin/zsh \
  GHOSTHUB_CONFIG_HOME="$scratch/ghosthub-config" \
  GHOSTHUB_STATE_HOME="$scratch/ghosthub-state" \
  GHOSTHUB_DEMO_ROOT="$demo_root" \
  GHOSTHUB_DEMO_SCRATCH="$scratch" \
  GHOSTHUB_DEMO_SSH_DIR="$scratch/ssh" \
  TMUX_TMPDIR="$scratch/tmux" \
  DYLD_INSERT_LIBRARIES="$scratch/libdemohost.dylib" \
  "$bin" -ApplePersistenceIgnoreState YES \
  -ghosthub.settings.hosts.ssh "<$hosts_hex>" \
  > "$scratch/app.log" 2>&1 &

demo_pid=$!
# Until the ownership record is durable, every exit path owns cleanup of this
# exact child. Reap it even if TERM is ignored so teardown can never delete the
# executable beneath an untracked live process.
cleanup_unrecorded_app() {
  local status=$?
  trap - EXIT HUP INT TERM
  if kill -0 "$demo_pid" 2>/dev/null; then
    kill "$demo_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$demo_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$demo_pid" 2>/dev/null; then
      kill -KILL "$demo_pid" 2>/dev/null || true
    fi
  fi
  wait "$demo_pid" 2>/dev/null || true
  exit "$status"
}
trap cleanup_unrecorded_app EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
demo_record_process "$demo_pid" "$pid_record" "$bin"
trap - EXIT HUP INT TERM
echo "Ghosthub demo instance launched (pid $demo_pid). Log: $scratch/app.log"
