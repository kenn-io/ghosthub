#!/usr/bin/env bash
# Tears down the faux demo environment: demo app instance, local tmux server,
# Docker remote, and scratch-owned SSH configuration and host keys.
set -euo pipefail

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scratch="${GHOSTHUB_DEMO_SCRATCH:-/tmp/ghosthub-demo}"
sentinel="$scratch/.ghosthub-demo-scratch"

# Never clean up state we cannot prove stage.sh created: a mistyped
# scratch path must not remove containers or SSH trust entries.
if [[ ! -f "$sentinel" ]]; then
  echo "nothing to tear down: no demo sentinel at $scratch" >&2
  exit 0
fi
# shellcheck source=SCRIPTDIR/scratch-guard.sh
source "$demo_root/scratch-guard.sh"
demo_scratch_guard "$scratch"

# shellcheck source=SCRIPTDIR/process.sh
source "$demo_root/process.sh"
demo_stop_retained_launches \
  "$scratch" "$scratch/app/Ghosthub.app/Contents/MacOS/Ghosthub"
demo_stop_recorded_process \
  "$scratch/app.pid" "$scratch/app/Ghosthub.app/Contents/MacOS/Ghosthub"
# Kill only via the explicit socket path: tmux silently falls back to the
# DEFAULT /tmp socket when TMUX_TMPDIR does not exist, and a fallback
# kill-server destroys every real session on the machine.
demo_socket="$scratch/tmux/tmux-$(id -u)/default"
# shellcheck source=SCRIPTDIR/tmux.sh
source "$demo_root/tmux.sh"
demo_stop_tmux_server "$demo_socket"
# Remove only the container this scratch's staging run recorded; the fixed
# name alone could belong to a different demo invocation.
# shellcheck source=SCRIPTDIR/docker-cleanup.sh
source "$demo_root/docker-cleanup.sh"
demo_remove_recorded_container "$scratch/remote.cid"

rm -rf "$scratch"
echo "demo environment removed"
