# shellcheck shell=bash
# Stop only the explicit demo server and confirm it no longer answers before
# callers delete the scratch directory that contains its control socket.
demo_stop_tmux_server() {
  local socket="$1"
  local attempts="${GHOSTHUB_DEMO_TMUX_STOP_ATTEMPTS:-30}"
  local delay="${GHOSTHUB_DEMO_TMUX_STOP_DELAY:-0.1}"
  local kill_output probe_output probe_status
  [[ -S "$socket" ]] || return 0

  kill_output="$(tmux -S "$socket" kill-server 2>&1)" || true
  for _ in $(seq 1 "$attempts"); do
    probe_status=0
    probe_output="$(tmux -S "$socket" list-sessions 2>&1)" || probe_status=$?
    if [[ "$probe_status" != 0 ]] && \
       grep -q '^no server running on ' <<< "$probe_output"; then
      return 0
    fi
    if [[ "$probe_status" != 0 ]]; then
      echo "error: cannot confirm demo tmux shutdown at $socket" >&2
      [[ -n "$kill_output" ]] && echo "       kill-server: $kill_output" >&2
      [[ -n "$probe_output" ]] && echo "       probe: $probe_output" >&2
      return 1
    fi
    sleep "$delay"
  done

  echo "error: demo tmux server remains active at $socket; preserving scratch" >&2
  [[ -n "$kill_output" ]] && echo "       kill-server: $kill_output" >&2
  return 1
}
