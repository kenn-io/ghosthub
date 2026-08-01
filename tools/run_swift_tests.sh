#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: $0 command [arguments...]" >&2
    exit 2
fi

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
current_uid=$(id -u)
# Keep this below tmux's Unix-socket path limit. The sticky /tmp parent and
# strict UID/mode checks in purge_test_tmux.sh protect the per-user hierarchy.
user_tmpdir="/tmp/ghosthub-$current_uid"
test_root="$user_tmpdir/tmux-tests"
umask 077
mkdir -m 700 "$user_tmpdir" 2>/dev/null || true
sh "$script_dir/purge_test_tmux.sh" --stale
mkdir -m 700 "$test_root" 2>/dev/null || true
sh "$script_dir/purge_test_tmux.sh" --stale
# Publishing the owner PID in the atomically created directory name lets
# concurrent stale sweeps distinguish active runs without a marker-file race.
tmux_tmpdir=$(mktemp -d "$test_root/run.$$.XXXXXX")
run_id=${tmux_tmpdir##*.}

cleanup() {
    status=$1
    trap - EXIT INT TERM HUP
    sh "$script_dir/purge_test_tmux.sh" "$tmux_tmpdir" || true
    exit "$status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

export TMUX_TMPDIR="$tmux_tmpdir"
export GHOSTHUB_TEST_TMUX_RUN_ID="$run_id"
"$@"
